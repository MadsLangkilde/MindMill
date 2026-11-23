import io
import json
import os
import subprocess
import sys
import shutil
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PLUGIN / "scripts"))
import kb  # noqa: E402


class KbTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "kb"
        self.repo_a = self.tmp / "repos" / "app-a"
        self.repo_b = self.tmp / "repos" / "app-b"
        for d in (self.repo_a / "worktrees" / "w1", self.repo_b):
            d.mkdir(parents=True)
        self.root.mkdir()
        (self.root / "kb.json").write_text(json.dumps({"version": 1, "projects": [
            {"id": "app-a", "title": "App A", "paths": [str(self.repo_a)], "related": ["shared"]},
            {"id": "app-b", "title": "App B", "paths": [str(self.repo_b)], "related": []},
            {"id": "shared", "title": "Shared", "paths": [], "related": []},
        ]}))
        for p in ("app-a", "app-b", "shared"):
            for s in kb.SECTIONS:
                (self.root / "projects" / p / s).mkdir(parents=True)
        self.env = {**os.environ, "KB_ROOT": str(self.root), "CLAUDE_PLUGIN_DATA": str(self.tmp / "data")}
        os.environ.update({"KB_ROOT": str(self.root), "CLAUDE_PLUGIN_DATA": str(self.tmp / "data")})

    def cli(self, *args, cwd=None, stdin=""):
        return subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), *args],
                              cwd=cwd or self.repo_a, env=self.env, input=stdin,
                              capture_output=True, text=True)

    def hook(self, event, payload, cwd=None):
        r = self.cli("hook", event, cwd=cwd, stdin=json.dumps(payload))
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)["hookSpecificOutput"]["additionalContext"] if r.stdout.strip() else ""


class ScopesTest(KbTestCase):
    def nest(self):
        (self.root / "kb.json").write_text(json.dumps({"version": 2, "projects": [
            {"id": "prod", "title": "Prod", "scopes": [
                {"id": "shared", "title": "Product-wide", "wide": True, "paths": [], "remotes": [], "related": []},
                {"id": "app-a", "title": "A", "paths": [str(self.repo_a)], "remotes": [], "related": []},
                {"id": "app-b", "title": "B", "paths": [str(self.repo_b)], "remotes": [], "related": []}]},
            {"id": "else", "title": "Else", "scopes": [{"id": "x", "title": "X", "wide": True, "paths": []}]}]}))
        for sec in kb.SECTIONS:
            (self.root / "projects" / "x" / sec).mkdir(parents=True, exist_ok=True)

    def test_v1_registry_is_one_project_per_scope(self):
        reg = kb.load_registry(self.root)
        self.assertEqual([(r["id"], r["project"], r["wide"]) for r in reg],
                         [("app-a", "app-a", True), ("app-b", "app-b", True), ("shared", "shared", True)])
        kb.save_registry(self.root, reg)
        data = json.loads((self.root / "kb.json").read_text())
        self.assertEqual(data["version"], 1)
        self.assertNotIn("project", data["projects"][0])

    def test_v2_registry_flattens_and_round_trips(self):
        self.nest()
        reg = kb.load_registry(self.root)
        self.assertEqual([(r["id"], r["project"], r["wide"]) for r in reg],
                         [("shared", "prod", True), ("app-a", "prod", False), ("app-b", "prod", False), ("x", "else", True)])
        self.assertEqual(kb.load_projects(self.root)[0], {"id": "prod", "title": "Prod", "scopes": ["shared", "app-a", "app-b"]})
        kb.save_registry(self.root, reg)
        data = json.loads((self.root / "kb.json").read_text())
        self.assertEqual([p["id"] for p in data["projects"]], ["prod", "else"])
        self.assertEqual(data["projects"][0]["scopes"][0], {"id": "shared", "title": "Product-wide", "wide": True,
                                                            "paths": [], "remotes": [], "related": []})
        self.assertNotIn("wide", data["projects"][0]["scopes"][1])

    def test_new_with_scopes_writes_the_field_only_when_needed(self):
        self.nest()
        one = self.cli("new", "fact", "--project", "shared", "--cross-project", "--title", "Plain").stdout.split()
        self.assertNotIn("scopes:", Path(one[1]).read_text())
        two = self.cli("new", "fact", "--project", "shared", "--cross-project", "--title", "Upload",
                       "--scopes", "app-a,shared").stdout.split()
        self.assertIn("scopes: [shared, app-a]", Path(two[1]).read_text())
        bad = self.cli("new", "fact", "--title", "Bad", "--scopes", "nope")
        self.assertIn("unknown scope nope", bad.stderr)
        other = self.cli("new", "fact", "--title", "Bad", "--scopes", "x")
        self.assertIn("belongs to project else", other.stderr)

    def test_scopes_command_get_set_add_remove(self):
        self.nest()
        fid = self.cli("new", "fact", "--title", "F").stdout.split()[0]
        self.assertEqual(self.cli("scopes", fid).stdout.split(), ["app-a"])
        self.assertEqual(self.cli("scopes", fid, "--add", "shared,app-b").stdout.split(), ["app-a", "shared", "app-b"])
        self.assertEqual(self.cli("scopes", fid, "--remove", "app-b").stdout.split(), ["app-a", "shared"])
        self.assertIn("move it", self.cli("scopes", fid, "--remove", "app-a").stderr)
        self.assertEqual(self.cli("scopes", fid, "--set", "app-b").stdout.split(), ["app-a", "app-b"])
        self.assertEqual(self.cli("scopes", fid, "--set", "").stdout.split(), ["app-a"])
        self.assertNotIn("scopes:", (self.root / "projects" / "app-a" / "facts" / f"{fid.split('/')[-1]}.md").read_text())

    def test_tags_command_keeps_the_users_removals(self):
        fid = self.cli("new", "fact", "--title", "Tokens", "--tags", "Auth, #BFF").stdout.split()[0]
        self.assertEqual(self.cli("tags", fid).stdout.split("\n")[:2], ["auth", "bff"])
        self.assertEqual(self.cli("tags", fid, "--remove", "bff").stdout.split(), ["auth"])
        self.assertEqual(self.cli("tags", fid, "--add", "bff,common repo", "--auto").stdout.strip().split("\n"),
                         ["auth", "common repo"])
        self.assertIn("only adds", self.cli("tags", fid, "--remove", "auth", "--auto").stderr)
        self.assertEqual(self.cli("tags", fid, "--add", "BFF").stdout.strip().split("\n"), ["auth", "common repo", "bff"])
        text = (self.root / "projects" / "app-a" / "facts" / f"{fid.split('/')[-1]}.md").read_text()
        self.assertIn("tags: [auth, common repo, bff]", text)
        self.assertNotIn("tags_off", text)
        self.cli("new", "fact", "--title", "Other", "--tags", "auth")
        self.assertEqual(json.loads(self.cli("tags", "--json").stdout)[0], {"tag": "auth", "count": 2})

    def test_fact_links_read_both_ways_and_unlink_from_either_side(self):
        a = self.cli("new", "fact", "--title", "The BFF issues tokens").stdout.split()[0]
        b = self.cli("new", "fact", "--title", "The device validates them").stdout.split()[0]
        self.cli("fact", "link", a, b)
        self.cli("fact", "link", b, a)
        self.assertEqual(kb.find_entry(self.root, a).get("related"), [b])
        self.assertEqual(kb.find_entry(self.root, b).get("related"), "")
        self.cli("fact", "link", b, a, "--remove")
        self.assertNotIn("related", (self.root / "projects" / "app-a" / "facts" / f"{a.split('/')[-1]}.md").read_text())
        self.assertIn("itself", self.cli("fact", "link", a, a).stderr)

    def test_merging_follow_ups_keeps_every_source_link(self):
        keep = self.cli("new", "followup", "--title", "Ask about token expiry", "--tags", "auth",
                        "--field", "raised_in=app-a/meetings/2026-11-01-sync", "--field", "due=2026-12-01").stdout.split()[0]
        dup = self.cli("new", "followup", "--title", "When do tokens expire?", "--tags", "bff",
                       "--field", "raised_in=app-a/facts/token-lifetime", "--field", "due=2026-11-25",
                       "--body-stdin", stdin="Asked by Pia.").stdout.split()[0]
        dup2 = self.cli("new", "followup", "--title", "Token expiry again",
                        "--field", "raised_in=app-a/meetings/2026-11-01-sync").stdout.split()[0]
        self.cli("followup", "propose-merge", keep, dup, "--why", "same question")
        self.assertEqual(len(json.loads(self.cli("followup", "merges", "--json").stdout)), 1)
        r = self.cli("followup", "merge", keep, dup, dup2)
        self.assertEqual(r.returncode, 0, r.stderr)
        k = kb.find_entry(self.root, keep)
        self.assertEqual(k.get("raised_in"), ["app-a/meetings/2026-11-01-sync", "app-a/facts/token-lifetime"])
        self.assertEqual(k.get("tags"), ["auth", "bff"])
        self.assertEqual(k.get("due"), "2026-11-25")
        self.assertIn("### When do tokens expire?", k.body)
        self.assertIn("Asked by Pia.", k.body)
        d = kb.find_entry(self.root, dup)
        self.assertEqual((d.status, d.get("merged_into")), ("dropped", keep))
        self.assertEqual(json.loads(self.cli("followup", "merges", "--json").stdout), [])

    def test_dismissed_merges_are_not_proposed_again(self):
        a = self.cli("new", "followup", "--title", "A").stdout.split()[0]
        b = self.cli("new", "followup", "--title", "B").stdout.split()[0]
        self.cli("followup", "propose-merge", a, b)
        self.cli("followup", "merges", "--dismiss", b, a)
        self.assertIn("not the same", self.cli("followup", "propose-merge", a, b).stdout)
        self.assertEqual(json.loads(self.cli("followup", "merges", "--json").stdout), [])

    def test_list_search_and_context_include_tagged_entries_once(self):
        self.nest()
        self.cli("new", "fact", "--project", "shared", "--cross-project", "--title", "Upload format",
                 "--scopes", "app-a", "--summary", "export formats")
        self.cli("new", "fact", "--project", "shared", "--cross-project", "--title", "Shared only")
        self.assertIn("Upload format", self.cli("list", "--scope", "app-a", "--section", "facts").stdout)
        self.assertNotIn("Shared only", self.cli("list", "--project", "app-a", "--section", "facts").stdout)
        self.assertIn("Upload format", self.cli("search", "export", "--project", "app-a").stdout)
        ctx = kb.build_context(self.root, self.repo_a)
        self.assertIn("## Project: Prod · scope A (`app-a`)", ctx)
        self.assertIn("`app-a` (A) ← this session", ctx)
        self.assertIn("`shared` (Product-wide, project-wide)", ctx)
        self.assertEqual(ctx.count("Upload format"), 1)
        self.assertIn("Shared only", ctx)
        self.assertIn("--scopes product,android", ctx)

    def test_project_add_converts_v1_and_scope_add_move(self):
        r = self.cli("project", "add", "--id", "acmego", "--title", "Acme Go", "--wide-scope", "go", "--wide-title", "Product-wide")
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads((self.root / "kb.json").read_text())
        self.assertEqual(data["version"], 2)
        self.assertEqual([p["id"] for p in data["projects"]], ["app-a", "app-b", "shared", "acmego"])
        self.assertTrue((self.root / "projects" / "go" / "facts").is_dir())
        for sid in ("app-a", "shared"):
            self.assertEqual(self.cli("scope", "move", sid, "--project", "acmego").returncode, 0)
        r = self.cli("scope", "add", "--project", "acmego", "--id", "comet", "--title", "Comet", "--paths", str(self.repo_b))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("already has a project-wide", self.cli("scope", "add", "--project", "acmego", "--id", "w2",
                                                             "--title", "W", "--wide").stderr)
        proj = {p["id"]: p["scopes"] for p in kb.load_projects(self.root)}
        self.assertEqual(proj["acmego"], ["go", "app-a", "shared", "comet"])
        self.assertNotIn("app-a", proj)
        wide = [sc["id"] for sc in kb.load_registry(self.root) if sc["project"] == "acmego" and sc["wide"]]
        self.assertEqual(wide, ["go"])
        self.assertIn("acmego\tcomet\tComet", self.cli("scope", "list").stdout)
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")

    def test_move_rewrites_the_scopes_field(self):
        self.nest()
        fid = self.cli("new", "fact", "--title", "F", "--scopes", "shared").stdout.split()[0]
        new = self.cli("move", fid, "--project", "app-b").stdout.split()
        self.assertIn("scopes: [app-b, shared]", Path(new[1]).read_text())
        fid2 = self.cli("new", "fact", "--title", "G", "--scopes", "app-b").stdout.split()[0]
        new2 = self.cli("move", fid2, "--project", "app-b").stdout.split()
        self.assertNotIn("scopes:", Path(new2[1]).read_text())

    def test_lint_flags_bad_scopes_and_wide_count(self):
        self.nest()
        (self.root / "projects" / "app-a" / "facts" / "f.md").write_text("---\ntitle: F\nscopes: [app-a, x, ghost]\n---\n")
        data = json.loads((self.root / "kb.json").read_text())
        data["projects"][0]["scopes"][1]["wide"] = True
        (self.root / "kb.json").write_text(json.dumps(data))
        out = self.cli("lint").stdout
        self.assertIn("app-a/facts/f: scope x is in another project", out)
        self.assertIn("app-a/facts/f: unknown scope ghost", out)
        self.assertIn("project prod needs exactly one project-wide scope", out)


class ScopeIncludesRemoveTest(KbTestCase):
    def setUp(self):
        super().setUp()
        ScopesTest.nest(self)

    def test_add_with_includes_and_members(self):
        r = self.cli("scope", "add", "--project", "prod", "--id", "mobile", "--title", "Mobile", "--includes", "app-a,app-b")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(kb.scope_map(self.root)["mobile"]["includes"], ["app-a", "app-b"])
        self.assertEqual(sorted(kb.scope_members(self.root, "mobile")), ["app-a", "app-b", "mobile"])
        self.assertEqual(sorted(kb.scope_members(self.root, "shared")), ["app-a", "app-b", "mobile", "shared"])
        bad = self.cli("scope", "add", "--project", "prod", "--id", "m2", "--title", "M2", "--includes", "x")
        self.assertNotEqual(bad.returncode, 0)

    def test_remove_moves_entries_and_drops_tags_and_includes(self):
        self.cli("scope", "add", "--project", "prod", "--id", "mobile", "--title", "Mobile", "--includes", "app-a,app-b")
        made = self.cli("new", "fact", "--project", "app-b", "--title", "B fact", "--cross-project")
        self.assertEqual(made.returncode, 0, made.stderr)
        tagged = self.cli("new", "fact", "--project", "app-a", "--title", "A fact", "--scopes", "app-b")
        self.assertEqual(tagged.returncode, 0, tagged.stderr)
        r = self.cli("scope", "remove", "app-b")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1 entry moved to shared", r.stdout)
        self.assertTrue((self.root / "projects" / "shared" / "facts" / "b-fact.md").exists())
        self.assertFalse((self.root / "projects" / "app-b").exists())
        self.assertNotIn("app-b", kb.scope_map(self.root))
        self.assertEqual(kb.scope_map(self.root)["mobile"]["includes"], ["app-a"])
        a = kb.find_entry(self.root, "app-a/facts/a-fact")
        self.assertEqual(kb.entry_scopes(a), ["app-a"])
        self.assertNotEqual(self.cli("scope", "remove", "shared").returncode, 0)


class TrackerScopeTest(unittest.TestCase):
    def test_scopes_of_item(self):
        owners = [({"id": "android"}, {"title_prefix": "Android: ", "tags": ["Android"]}),
                  ({"id": "ios"}, {"title_prefix": "iOS: ", "tags": ["iOS"]})]
        f = lambda title, tags=(): kb.scopes_of_item(title, list(tags), owners, "wide")
        self.assertEqual(f("Android: Fix it"), ["android"])
        self.assertEqual(f("iOS/Android: Align"), ["android", "ios"])
        self.assertEqual(f("iOS + Android: Align"), ["android", "ios"])
        self.assertEqual(f("Wrong names", ["Android", "iOS"]), ["android", "ios"])
        self.assertEqual(f("Backend work"), ["wide"])
        self.assertEqual(f("Androidish: no"), ["wide"])


class PeopleTest(KbTestCase):
    def test_initials_search_and_add(self):
        self.assertEqual(kb.initials_for("Petra Gray Hill", "pgh@example.com"), "PGH")
        self.assertEqual(kb.initials_for("Erik Nord", "ext1001@example.com"), "EN")
        cache = self.tmp / "people-directory.json"
        cache.write_text(json.dumps({"people": [{"name": "Petra Gray Hill", "email": "pgh@example.com"},
                                                {"name": "Peder Hanley", "email": "phan@example.com"}]}))
        self.env["KB_PEOPLE_CACHE"] = str(cache)
        os.environ["KB_PEOPLE_CACHE"] = str(cache)
        self.assertEqual(self.cli("people", "add", "--name", "Ole from Contoso").returncode, 0)
        self.assertEqual(self.cli("people", "add", "--name", "Peder Hanley").returncode, 0)
        reg = {p["name"]: p for p in kb.read_people_registry(self.root)}
        self.assertEqual(reg["Ole from Contoso"]["source"], "manual")
        self.assertEqual(reg["Peder Hanley"]["email"], "phan@example.com")
        self.assertEqual(reg["Peder Hanley"]["initials"], "PHAN")
        found = json.loads(self.cli("people", "search", "pe", "--json").stdout)
        self.assertEqual([p["name"] for p in found], ["Peder Hanley", "Petra Gray Hill"])
        self.assertEqual(json.loads(self.cli("people", "search", "pgh", "--json").stdout)[0]["name"], "Petra Gray Hill")
        self.assertEqual(len(kb.all_people(self.root)), 3)


class FrontmatterTest(unittest.TestCase):
    def test_round_trip_keeps_order_unknown_keys_and_lists(self):
        text = '---\ntitle: "A: b"\ndate: 2026-11-04\ncustom: keep me\ntags: [x, "y, z"]\n---\n\nBody\n'
        fields, body = kb.split_frontmatter(text)
        self.assertEqual([k for k, _ in fields], ["title", "date", "custom", "tags"])
        self.assertEqual(dict(fields)["tags"], ["x", "y, z"])
        again = kb.render_entry(fields, body)
        self.assertEqual(kb.split_frontmatter(again), (fields, body))

    def test_no_frontmatter_is_all_body(self):
        self.assertEqual(kb.split_frontmatter("# Hi\n"), ([], "# Hi\n"))

    def test_slug_cuts_on_a_word_boundary(self):
        s = kb.slugify("Hub note upload carries an export format plus the time zone and retry settings")
        self.assertLessEqual(len(s), 50)
        self.assertFalse(s.endswith("-"))
        self.assertEqual(s, "hub-note-upload-carries-an-export-format-plus-the")
        self.assertEqual(kb.slugify("Måling på øen"), "maaling-paa-oeen")


class ResolveTest(KbTestCase):
    def test_worktree_resolves_to_the_enclosing_repo(self):
        r = self.cli("resolve", "--cwd", str(self.repo_a / "worktrees" / "w1"))
        self.assertEqual(r.stdout.strip(), "app-a")

    def test_longest_path_wins(self):
        nested = self.repo_a / "worktrees" / "w1"
        data = json.loads((self.root / "kb.json").read_text())
        data["projects"][1]["paths"].append(str(nested))
        (self.root / "kb.json").write_text(json.dumps(data))
        self.assertEqual(self.cli("resolve", "--cwd", str(nested)).stdout.strip(), "app-b")

    def test_unregistered_directory(self):
        r = self.cli("resolve", "--cwd", str(self.tmp))
        self.assertEqual(r.returncode, 1)


class WriteTest(KbTestCase):
    def test_new_decision_and_supersede_marks_the_old_one(self):
        old = self.cli("new", "decision", "--title", "Use A", "--summary", "A", "--date", "2026-01-01").stdout.split()[0]
        new = self.cli("new", "decision", "--title", "Use B", "--supersedes", old, "--body", "B").stdout.split()[0]
        o = kb.find_entry(self.root, old)
        n = kb.find_entry(self.root, new)
        self.assertEqual((o.status, o.get("superseded_by")), ("superseded", new))
        self.assertEqual(n.get("supersedes"), [old])
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")

    def test_writing_into_another_project_needs_cross_project(self):
        r = self.cli("new", "fact", "--project", "app-b", "--title", "Leak")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refusing", r.stderr)
        self.assertEqual(list((self.root / "projects" / "app-b" / "facts").iterdir()), [])
        ok = self.cli("new", "fact", "--project", "shared", "--cross-project", "--title", "Fine")
        self.assertEqual(ok.returncode, 0, ok.stderr)

    def test_default_project_is_the_session_project(self):
        r = self.cli("new", "fact", "--title", "Here", cwd=self.repo_b)
        self.assertTrue(r.stdout.startswith("app-b/facts/here"))

    def test_lint_catches_dangling_supersede(self):
        p = self.root / "projects" / "app-a" / "decisions" / "2026-01-01-x.md"
        p.write_text("---\ntitle: X\ndate: 2026-01-01\nstatus: superseded\nsuperseded_by: app-a/decisions/nope\n---\n")
        r = self.cli("lint")
        self.assertEqual(r.returncode, 1)
        self.assertIn("points nowhere", r.stdout)


class ContextTest(KbTestCase):
    def test_context_lists_own_and_related_but_not_unrelated_or_superseded(self):
        self.cli("new", "decision", "--title", "Mine", "--summary", "own")
        old = self.cli("new", "decision", "--title", "Old one", "--date", "2025-01-01").stdout.split()[0]
        self.cli("new", "decision", "--title", "New one", "--supersedes", old)
        self.cli("new", "decision", "--project", "shared", "--cross-project", "--title", "Shared rule")
        self.cli("new", "fact", "--title", "Other app secret", cwd=self.repo_b)
        ctx = self.hook("session-start", {"session_id": "s1", "cwd": str(self.repo_a)})
        self.assertIn("**Mine**", ctx)
        self.assertIn("**New one**", ctx)
        self.assertNotIn("Old one", ctx)
        self.assertIn("Related, reference only: Shared", ctx)
        self.assertIn("Shared rule", ctx)
        self.assertNotIn("Other app secret", ctx)

    def test_drafts_stay_out_of_context_and_lists_until_saved(self):
        draft = self.root / "projects" / "app-a" / "followups" / "2026-01-01-half-typed.md"
        draft.write_text("---\ntitle: Half typed\ndate: 2026-01-01\nkind: action\nstatus: open\ndraft: true\n---\n")
        ctx = self.hook("session-start", {"session_id": "s1", "cwd": str(self.repo_a)})
        self.assertNotIn("Half typed", ctx)
        self.assertNotIn("Half typed", self.cli("list", "--section", "followups").stdout)
        self.assertIn("Half typed", self.cli("show", "app-a/followups/2026-01-01-half-typed").stdout)
        draft.write_text(draft.read_text().replace("draft: true\n", ""))
        self.assertIn("Half typed", self.cli("list", "--section", "followups").stdout)

    def test_unregistered_directory_gets_a_short_note(self):
        ctx = self.hook("session-start", {"session_id": "s2", "cwd": str(self.tmp)})
        self.assertIn("not registered", ctx)
        self.assertNotIn("How to use", ctx)


class ChangeReportTest(KbTestCase):
    def test_external_edit_is_reported_once_and_own_writes_are_not(self):
        fact = self.cli("new", "fact", "--title", "Speed").stdout.split()[1]
        self.hook("session-start", {"session_id": "s3", "cwd": str(self.repo_a)})
        self.assertEqual(self.hook("prompt", {"session_id": "s3"}), "")

        time.sleep(0.01)
        Path(fact).write_text("---\ntitle: Speed\n---\n\nedited in the app\n")
        report = self.hook("prompt", {"session_id": "s3"})
        self.assertIn("edited: `app-a/facts/speed`", report)
        self.assertEqual(self.hook("prompt", {"session_id": "s3"}), "")

        time.sleep(0.01)
        Path(fact).write_text("---\ntitle: Speed\n---\n\nedited by Claude\n")
        self.hook("post-tool", {"session_id": "s3", "tool_input": {"file_path": fact}})
        self.assertEqual(self.hook("prompt", {"session_id": "s3"}), "")

    def test_changes_in_unrelated_projects_are_not_reported(self):
        self.hook("session-start", {"session_id": "s4", "cwd": str(self.repo_a)})
        self.cli("new", "fact", "--title", "Elsewhere", cwd=self.repo_b)
        self.assertEqual(self.hook("prompt", {"session_id": "s4"}), "")

    def test_hooks_survive_garbage_input(self):
        r = self.cli("hook", "prompt", stdin="not json")
        self.assertEqual(r.returncode, 0)


class InboxTest(KbTestCase):
    def test_approve_moves_into_section_strips_fields_and_supersedes(self):
        old = self.cli("new", "decision", "--title", "Use A", "--date", "2026-01-01").stdout.split()[0]
        r = self.cli("inbox", "add", "--section", "decisions", "--title", "Use B", "--supersedes", old,
                     "--proposed-by", "app-a/meetings/2026-02-02-sync", "--reason", "said in the meeting",
                     "--date", "2026-02-02", "--body", "B")
        self.assertEqual(r.returncode, 0, r.stderr)
        inbox_id = r.stdout.split()[0]
        self.assertTrue(inbox_id.startswith("app-a/inbox/"))
        self.assertEqual(kb.find_entry(self.root, old).status, "active")
        self.assertNotIn("Use B", self.cli("context").stdout)
        listed = self.cli("inbox", "list", "--project", "app-a", "--proposed-by", "app-a/meetings/2026-02-02-sync")
        self.assertIn(inbox_id, listed.stdout)

        new_id = self.cli("inbox", "approve", inbox_id).stdout.split()[0]
        self.assertEqual(new_id, "app-a/decisions/2026-02-02-use-b")
        new = kb.find_entry(self.root, new_id)
        self.assertEqual([k for k in dict(new.fields) if k in kb.INBOX_ONLY_FIELDS], [])
        self.assertEqual(kb.find_entry(self.root, old).get("superseded_by"), new_id)
        self.assertIsNone(kb.find_entry(self.root, inbox_id))
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")

    def test_reject_deletes(self):
        inbox_id = self.cli("inbox", "add", "--section", "facts", "--title", "Maybe",
                            "--proposed-by", "session:x").stdout.split()[0]
        self.assertEqual(self.cli("inbox", "reject", inbox_id).returncode, 0)
        self.assertEqual(list((self.root / "projects" / "app-a" / "inbox").iterdir()), [])

    def test_inbox_respects_project_separation(self):
        r = self.cli("inbox", "add", "--project", "app-b", "--section", "facts", "--title", "X",
                     "--proposed-by", "session:x")
        self.assertNotEqual(r.returncode, 0)

    def test_own_cli_writes_are_not_reported_back(self):
        self.hook("session-start", {"session_id": "s9", "cwd": str(self.repo_a)})
        cmd = "kb inbox add --section facts --title Mine --proposed-by session:s9"
        self.cli(*cmd.split()[1:])
        self.hook("post-tool", {"session_id": "s9", "tool_name": "Bash", "tool_input": {"command": cmd}})
        self.assertEqual(self.hook("prompt", {"session_id": "s9"}), "")


class FollowupBacklogSettingsTest(KbTestCase):
    def test_new_followup_already_done_in_another_project(self):
        r = self.cli("new", "followup", "--project", "app-b", "--cross-project", "--title", "Declare trader status",
                     "--field", "status=done", "--field", "resolved_by=Eva declared it")
        self.assertEqual(r.returncode, 0, r.stderr)
        text = (self.root / "projects" / "app-b" / "followups" / f"{r.stdout.split()[0].split('/')[-1]}.md").read_text()
        self.assertIn("status: done", text)
        self.assertIn("kind: action", text)
        self.assertNotIn("status: open", text)
        self.assertIn("resolved_by: Eva declared it", text)
        bad = self.cli("new", "followup", "--title", "X", "--field", "status=finished")
        self.assertNotEqual(bad.returncode, 0)

    def test_titles_are_one_line(self):
        r = self.cli("new", "followup", "--title", "Profile alignments\nProfile screen alignment", "--summary", "a\\nb")
        text = (self.root / "projects" / "app-a" / "followups" / f"{r.stdout.split()[0].split('/')[-1]}.md").read_text()
        self.assertIn("title: Profile alignments Profile screen alignment\n", text)
        self.assertIn("summary: a b\n", text)

    def test_several_resolved_by_links_become_a_list(self):
        fid = self.cli("new", "followup", "--title", "Make PBIs").stdout.split()[0]
        u1 = "https://dev.azure.com/O/P/_workitems/edit/1"
        u2 = "https://dev.azure.com/O/P/_workitems/edit/2"
        r = self.cli("followup", "close", fid, "--status", "done", "--resolved-by", f"{u1}, {u2}")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"resolved_by: [\"{u1}\", \"{u2}\"]", (self.root / "projects" / f"{fid.split('/', 1)[0]}" / "followups" / f"{fid.split('/')[-1]}.md").read_text())
        fid2 = self.cli("new", "followup", "--title", "Ask Tom").stdout.split()[0]
        self.cli("followup", "close", fid2, "--status", "done", "--resolved-by", "Tom said yes on Teams")
        self.assertIn("resolved_by: Tom said yes on Teams", (self.root / "projects" / "app-a" / "followups" / f"{fid2.split('/')[-1]}.md").read_text())

    def test_followup_close_and_context(self):
        fid = self.cli("new", "followup", "--type", "question", "--title", "Which export format?",
                       "--field", "owner=BFF").stdout.split()[0]
        self.assertIn("Which export format?", self.cli("context").stdout)
        self.cli("followup", "close", fid, "--status", "done", "--answer", "After retry")
        e = kb.find_entry(self.root, fid)
        self.assertEqual((e.status, e.summary), ("done", "After retry"))
        self.assertNotIn("Which export format?", self.cli("context").stdout)

    def test_followup_handled_by_kb_reopens_and_takes_notes(self):
        fid = self.cli("new", "followup", "--type", "question", "--title", "Who signs off?").stdout.split()[0]
        self.cli("followup", "note", fid, "--text", "Lena is asked  first", "--by", "app-a/facts/x")
        self.cli("followup", "note", fid, "--text", "He agreed")
        e = kb.find_entry(self.root, fid)
        self.assertIn("## Updates", e.body)
        self.assertEqual(e.body.count("## Updates"), 1)
        self.assertIn("Lena is asked first (app-a/facts/x)", e.body)
        self.cli("followup", "close", fid, "--status", "done", "--auto", "--resolved-by", "app-a/facts/x",
                 "--answer", "Lena signs off")
        e = kb.find_entry(self.root, fid)
        self.assertEqual((e.status, e.get("closed_by"), e.get("resolved_by")), ("done", "kb", "app-a/facts/x"))
        self.assertTrue(e.get("closed"))
        self.cli("followup", "close", fid, "--status", "open")
        e = kb.find_entry(self.root, fid)
        self.assertEqual((e.status, e.get("closed_by"), e.get("closed")), ("open", "", ""))

    def test_settings_set_get(self):
        self.cli("settings", "set", "tracker.title_prefix", "App A: ")
        self.cli("settings", "set", "tracker.tags", '["Android"]')
        self.assertEqual(self.cli("settings", "get", "tracker.title_prefix").stdout, "App A: \n")
        self.assertEqual(json.loads(self.cli("settings", "get", "tracker.tags").stdout), ["Android"])

    def test_backlog_dry_run_uses_settings_and_needs_no_credentials(self):
        self.cli("settings", "set", "tracker", json.dumps({
            "kind": "azure-devops", "organization": "Org", "project": "Proj",
            "title_prefix": "App A: ", "tags": ["Android"], "area_path": "Proj\\Team"}))
        bid = self.cli("new", "backlog", "--type", "pbi", "--title", "Upload export format", "--tags", "upload",
                       "--source", "app-a/meetings/x", "--body-stdin",
                       stdin="## Description\nSend it.\n\n## Acceptance criteria\n- raw is sent\n").stdout.split()[0]
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "backlog", "create", bid,
                            "--sprint", "none"], cwd=self.repo_a, capture_output=True, text=True,
                           env={**self.env, "HOME": str(self.tmp)})
        self.assertEqual(r.returncode, 2, r.stderr)
        plan = json.loads(r.stdout)
        values = {op["path"]: op["value"] for op in plan["operations"]}
        self.assertEqual(values["/fields/System.Title"], "App A: Upload export format")
        # KB tags stay in the KB: only the scope's tracker tags go, until a tag is aligned.
        self.assertEqual(values["/fields/System.Tags"], "Android")
        self.assertIn("<li>raw is sent</li>", values["/fields/Microsoft.VSTS.Common.AcceptanceCriteria"])
        self.assertEqual(kb.find_entry(self.root, bid).status, "proposed")
        kb.save_item_tags(self.root, {"version": 1, "items": {}, "aligned_tags": ["upload"]})
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "backlog", "create", bid,
                            "--sprint", "none"], cwd=self.repo_a, capture_output=True, text=True,
                           env={**self.env, "HOME": str(self.tmp)})
        values = {op["path"]: op["value"] for op in json.loads(r.stdout)["operations"]}
        self.assertEqual(values["/fields/System.Tags"], "Android; upload")

    def test_local_tags_never_reach_the_tracker_unless_aligned(self):
        self.assertEqual(kb.tracker_tag_additions(["auth", "bff"], [], ["Android"]), [])
        self.assertEqual(kb.tracker_tag_additions(["auth", "bff"], ["bff", "ios"], ["Android"]), ["bff"])
        self.assertEqual(kb.tracker_tag_additions(["auth"], ["auth"], ["Auth"]), [])
        store = {"version": 1, "aligned_tags": ["release"], "items": {
            "azure-devops:7": {"tags": ["auth", "bff", "release"], "aligned": ["bff"]}}}
        self.assertEqual(kb.item_tag_additions(store, "azure-devops:7", ["Android"]), ["bff", "release"])
        self.assertEqual(kb.item_tag_additions(store, "azure-devops:8", []), [])

    def test_tracker_tag_writes_only_aligned_tags_and_keeps_the_tools_own(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "O", "project": "P"}))
        kb.save_item_tags(self.root, {"version": 1, "aligned_tags": [], "items": {
            "azure-devops:7": {"tags": ["auth", "bff"], "aligned": ["bff"]}}})
        self.assertIn("--yes", self.cli("tracker", "tag", "7").stderr)
        sent = []

        def fake(method, url, pat, body=None, content_type="application/json"):
            if method == "GET":
                return {"id": 7, "fields": {"System.Tags": "Android; Release"}}
            sent.append(body)
            return {}
        orig = (kb.ado_request, kb.ado_pat)
        kb.ado_request, kb.ado_pat = fake, (lambda: "pat")
        try:
            self.assertEqual(kb.align_item_tags(self.root, 7), "#7: added bff")
        finally:
            kb.ado_request, kb.ado_pat = orig
        self.assertEqual(sent, [[{"op": "add", "path": "/fields/System.Tags", "value": "Android; Release; bff"}]])

    def test_pr_comment_starts_a_new_active_thread(self):
        sent = []

        def fake(method, url, pat, body=None, content_type="application/json"):
            sent.append((method, url, body))
            return {"id": 41}
        orig = (kb.ado_request, kb.ado_pat, kb.find_pr)
        kb.ado_request, kb.ado_pat = fake, (lambda: "pat")
        kb.find_pr = lambda root, pr_id, pat: ("O", "P", [], "https://api", {"repository": {"id": "r1"}})
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                code = kb.main(["pr", "comment", "12", "--text", " Looks good "])
        finally:
            kb.ado_request, kb.ado_pat, kb.find_pr = orig
        self.assertEqual(code, 0)
        self.assertIn("thread 41", out.getvalue())
        self.assertEqual(sent, [("POST", "https://api/git/repositories/r1/pullRequests/12/threads?api-version=7.1",
                                 {"comments": [{"parentCommentId": 0, "content": "Looks good", "commentType": 1}],
                                  "status": "active"})])

    def test_backlog_assignee_name_is_sent_as_email(self):
        cache = self.tmp / "people-directory.json"
        cache.write_text(json.dumps({"people": [{"name": "Peder Hanley", "email": "phan@example.com"}]}))
        self.env["KB_PEOPLE_CACHE"] = str(cache)
        self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "O", "project": "P"}))
        bid = self.cli("new", "backlog", "--type", "pbi", "--title", "T", "--field", "assignee=Peder Hanley").stdout.split()[0]
        values = {op["path"]: op["value"] for op in json.loads(self.cli("backlog", "create", bid, "--sprint", "none").stdout)["operations"]}
        self.assertEqual(values["/fields/System.AssignedTo"], "phan@example.com")
        self.assertEqual(kb.find_entry(self.root, bid).get("assignee"), "Peder Hanley")

    def test_backlog_needs_organization_and_project(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "", "project": ""}))
        bid = self.cli("new", "backlog", "--type", "pbi", "--title", "T").stdout.split()[0]
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "backlog", "create", bid,
                            "--sprint", "none"], cwd=self.repo_a, capture_output=True, text=True,
                           env={**self.env, "HOME": str(self.tmp)})
        self.assertEqual(r.returncode, 1)
        self.assertIn("no organization or project set", r.stderr)

    def test_ado_error_detail_drops_the_html_page(self):
        import io
        import urllib.error
        page = io.BytesIO(b"<!DOCTYPE html >\n<html><head><title>404 - Page not found</title>")
        exc = urllib.error.HTTPError("https://dev.azure.com//_apis/x", 404, "Not Found", {}, page)
        self.assertEqual(kb.ado_error_detail(exc), "HTTP 404 Not Found for https://dev.azure.com//_apis/x")
        exc = urllib.error.HTTPError("u", 400, "Bad", {}, io.BytesIO(b'{"message": "TF401320: Rule error"}'))
        self.assertEqual(kb.ado_error_detail(exc), "TF401320: Rule error")

    def test_backlog_entry_overrides_and_none(self):
        self.cli("settings", "set", "tracker", json.dumps({
            "kind": "azure-devops", "organization": "Org", "project": "Proj", "area_path": "Proj\\Team",
            "assignee": "someone", "default_parent": 7}))
        bid = self.cli("new", "backlog", "--type", "pbi", "--title", "T", "--field", "area=Proj\\\\Other",
                       "--field", "assignee=none", "--field", "parent=none").stdout.split()[0]
        r = self.cli("backlog", "create", bid, "--sprint", "none")
        values = {op["path"]: op["value"] for op in json.loads(r.stdout)["operations"]}
        self.assertEqual(values["/fields/System.AreaPath"], "Proj\\Other")
        self.assertNotIn("/fields/System.AssignedTo", values)
        self.assertNotIn("/relations/-", values)

    def test_kb_references_never_reach_the_work_item(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "O", "project": "P"}))
        body = ("## Description\nKeyed by serial (decision app-a/decisions/2026-11-04-per-device). "
                "Source: sprint planning, 2026-11-09 (app-a/meetings/2026-11-09-sprint-planning).\n"
                "Today `Auth` (`data/x/src/main/Auth.kt`) answers.\n\n## Acceptance criteria\n- Works (see `kb://open?id=x`)\n")
        bid = self.cli("new", "backlog", "--type", "pbi", "--title", "T", "--body-stdin", stdin=body).stdout.split()[0]
        r = self.cli("backlog", "create", bid, "--sprint", "none")
        values = {op["path"]: op["value"] for op in json.loads(r.stdout)["operations"]}
        posted = values["/fields/System.Description"] + json.dumps(values)
        self.assertNotIn("decisions/", posted)
        self.assertNotIn("meetings/", posted)
        self.assertNotIn("kb://", posted)
        self.assertIn("Keyed by serial.", values["/fields/System.Description"])
        self.assertIn("Source: sprint planning, 2026-11-09.", values["/fields/System.Description"])
        self.assertIn("data/x/src/main/Auth.kt", values["/fields/System.Description"])
        self.assertIn("left out of the work item", r.stderr)

        bare = "## Description\nAs decided in app-a/decisions/2026-11-04-per-device we key by serial.\n"
        bid2 = self.cli("new", "backlog", "--type", "pbi", "--title", "U", "--body-stdin", stdin=bare).stdout.split()[0]
        r = self.cli("backlog", "create", bid2, "--sprint", "none")
        self.assertEqual(r.stdout, "")
        self.assertIn("only exist on this machine", r.stderr)

    def test_my_work_sorts_items_by_stage_links_prs_and_finds_reviews(self):
        (self.root / "kb.json").write_text(json.dumps({"version": 1, "projects": [
            {"id": "app-a", "title": "App A", "paths": [str(self.repo_a)], "remotes": ["_git/app-a"]},
            {"id": "app-b", "title": "App B", "paths": [str(self.repo_b)], "remotes": ["_git/app-b"]}]}))
        for pid, prefix in (("app-a", "A: "), ("app-b", "B: ")):
            self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "O", "project": "P",
                                                                "title_prefix": prefix}), "--project", pid)
        def fake(method, url, pat, body=None, content_type=None):
            if "connectionData" in url:
                return {"authenticatedUser": {"id": "me", "providerDisplayName": "Me"}}
            if "/wiql" in url:
                return {"workItems": [{"id": 1}, {"id": 2}, {"id": 3}]}
            if "/wit/workitems?" in url:
                f = lambda i, t, st: {"id": i, "fields": {"System.Title": t, "System.State": st, "System.WorkItemType": "Product Backlog Item",
                                                          "System.IterationPath": "P\\S1"}}
                return {"value": [f(1, "A: First", "New"), f(2, "A: Second", "Committed"), f(3, "B: Third", "Approved")]}
            if "/workitems?api" in url and "pullRequests/10/" in url:
                return {"value": [{"id": "2"}]}
            if "pullrequests?" in url:
                pr = lambda i, repo, who, revs=(), draft=False: {"pullRequestId": i, "title": f"PR {i}", "isDraft": draft,
                    "repository": {"name": repo, "id": repo}, "createdBy": {"id": who, "displayName": who}, "reviewers": list(revs)}
                return {"value": [pr(10, "app-a", "me"), pr(11, "app-a", "bob"), pr(12, "app-a", "bob", draft=True),
                                  pr(13, "other", "bob", [{"id": "me", "vote": 0, "isRequired": True}]),
                                  pr(14, "app-a", "bob", [{"id": "me", "vote": 10}]), pr(15, "web", "eve")]}
            raise AssertionError(url)
        orig = (kb.ado_request, kb.ado_pat)
        kb.ado_request, kb.ado_pat = fake, (lambda: "pat")
        try:
            work = kb.my_work(self.root)
        finally:
            kb.ado_request, kb.ado_pat = orig
        by_id = {i["id"]: i for i in work["items"]}
        self.assertEqual(by_id[1]["stage"], "not_started")
        self.assertEqual(by_id[2]["stage"], "in_pr")
        self.assertEqual(by_id[2]["prs"][0]["id"], 10)
        self.assertEqual(by_id[1]["title"], "First")
        self.assertEqual(by_id[3]["project"], "app-b")
        self.assertEqual(sorted(r["id"] for r in work["reviews"]), [11, 13])

    def test_stale_iteration_root_is_an_error_not_no_sprint(self):
        tracker = {"organization": "O", "project": "P", "iteration_root": "P\\Old"}
        orig = kb.ado_sprints
        kb.ado_sprints = lambda t, pat: [{"path": "P\\Old\\S1", "when": "past"}]
        try:
            with self.assertRaises(SystemExit) as ctx:
                kb.ado_sprint(tracker, "pat", "current")
            self.assertIn("kb tracker sprints", str(ctx.exception))
            kb.ado_sprints = lambda t, pat: [{"path": "P\\Old\\S1", "when": "past"},
                                             {"path": "P\\Old\\S2", "when": "current"},
                                             {"path": "P\\Old\\S3", "when": "future"}]
            self.assertEqual(kb.ado_sprint(tracker, "pat", "current"), "P\\Old\\S2")
            self.assertEqual(kb.ado_sprint(tracker, "pat", "next"), "P\\Old\\S3")
        finally:
            kb.ado_sprints = orig

    def test_backlog_condition_for_sprint_and_search(self):
        self.assertIn("NOT IN ('Done', 'Removed', 'Closed')", kb.backlog_condition(14, None, None))
        self.assertEqual(kb.backlog_condition(14, "P\\S1", None),
                         "[System.IterationPath] = 'P\\S1' AND [System.State] <> 'Removed'")
        self.assertEqual(kb.backlog_condition(14, None, "#123"), "[System.Id] = 123")
        self.assertEqual(kb.backlog_condition(14, None, "login o'brien"),
                         "[System.State] <> 'Removed' AND [System.Title] CONTAINS 'login' AND [System.Title] CONTAINS 'o''brien'")

    def test_states_in_workflow_order(self):
        got = kb.workflow_order([{"name": n, "category": c} for n, c in (
            ("Approved", "Proposed"), ("Blocked", "InProgress"), ("Done", "Completed"), ("In Progress", "InProgress"),
            ("New", "Proposed"), ("Removed", "Removed"), ("Resolved", "Resolved"))])
        self.assertEqual([x["name"] for x in got], ["New", "Approved", "In Progress", "Blocked", "Resolved", "Done", "Removed"])

    def test_sprint_backlog_reads_one_iteration_without_sprints_or_states(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "O", "project": "P",
                                                            "iteration_root": "P\\R"}))
        queries, urls = [], []

        def fake(method, url, pat, body=None, content_type=None):
            urls.append(url)
            if "connectionData" in url:
                return {"authenticatedUser": {"id": "me"}}
            if "/wiql" in url:
                queries.append(body["query"])
                return {"workItems": [{"id": 7}]}
            if "pullrequests?" in url:
                return {"value": []}
            if "/wit/workitems?" in url:
                return {"value": [{"id": 7, "fields": {"System.Title": "Old", "System.State": "Done",
                                                       "System.WorkItemType": "Bug", "System.IterationPath": "P\\R\\S1"}}]}
            raise AssertionError(url)
        orig = (kb.ado_request, kb.ado_pat)
        kb.ado_request, kb.ado_pat = fake, (lambda: "pat")
        try:
            data = kb.tracker_backlog(self.root, sprint="P\\R\\S1")
        finally:
            kb.ado_request, kb.ado_pat = orig
        self.assertIn("[System.IterationPath] = 'P\\R\\S1'", queries[0])
        self.assertEqual([(i["id"], i["stage"]) for i in data["items"]], [(7, "done")])
        self.assertFalse(any("classificationnodes" in u or "/states" in u for u in urls))
        self.assertNotIn("sprint_list", data)

    def test_move_sets_iteration_path(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "O", "project": "P"}))
        sent = []

        def fake(method, url, pat, body=None, content_type=None):
            sent.append((method, url, body))
            return {}
        orig = (kb.ado_request, kb.ado_pat)
        kb.ado_request, kb.ado_pat = fake, (lambda: "pat")
        try:
            lines = kb.set_work_item_fields(self.root, [5, 6], {"System.IterationPath": "P\\S2"}, "moved to S2")
        finally:
            kb.ado_request, kb.ado_pat = orig
        self.assertEqual(lines, ["#5 moved to S2", "#6 moved to S2"])
        self.assertEqual(sent[0][2], [{"op": "add", "path": "/fields/System.IterationPath", "value": "P\\S2"}])
        self.assertTrue(sent[1][1].endswith("/workitems/6?api-version=7.1"))

    def test_in_progress_state_per_process(self):
        scrum = [{"name": n, "category": c} for n, c in (("Done", "Completed"), ("Committed", "InProgress"),
                                                          ("New", "Proposed"), ("Approved", "Proposed"))]
        agile = [{"name": n, "category": c} for n, c in (("Active", "InProgress"), ("New", "Proposed"),
                                                          ("Resolved", "Resolved"), ("Closed", "Completed"))]
        self.assertEqual(kb.in_progress_state("Approved", scrum), "Committed")
        self.assertEqual(kb.in_progress_state("new", agile), "Active")
        self.assertIsNone(kb.in_progress_state("Committed", scrum))
        self.assertIsNone(kb.in_progress_state("Resolved", agile))
        self.assertIsNone(kb.in_progress_state("Done", scrum))

    def test_start_moves_an_unstarted_item_once(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "O", "project": "P"}))
        state = {"now": "New"}
        patched = []

        def fake(method, url, pat, body=None, content_type=None):
            if method == "PATCH":
                patched.append(body)
                state["now"] = body[0]["value"]
                return {}
            if "/states" in url:
                self.assertIn("Product%20Backlog%20Item", url)
                return {"value": [{"name": "New", "category": "Proposed"}, {"name": "Committed", "category": "InProgress"}]}
            return {"fields": {"System.State": state["now"], "System.WorkItemType": "Product Backlog Item"}}
        orig = (kb.ado_request, kb.ado_pat)
        kb.ado_request, kb.ado_pat = fake, (lambda: "pat")
        try:
            self.assertEqual(kb.start_work_item(self.root, "app-a", 5), "#5 is now Committed")
            self.assertEqual(kb.start_work_item(self.root, "app-a", 5), "#5 is already Committed")
        finally:
            kb.ado_request, kb.ado_pat = orig
        self.assertEqual(patched, [[{"op": "add", "path": "/fields/System.State", "value": "Committed"}]])

    def test_start_in_local_tracker_and_refusal_for_jira(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "local"}))
        self.cli("work", "add", "pbi", "Login")
        self.assertEqual(self.cli("tracker", "start", "1").stdout, "#1 is now Committed\n")
        self.assertEqual(self.cli("tracker", "start", "#1").stdout, "#1 is already Committed\n")
        self.cli("settings", "set", "tracker", json.dumps({"kind": "jira"}))
        r = self.cli("tracker", "start", "1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("connector", r.stderr)

    def test_bug_without_found_in_is_refused(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "azure-devops", "organization": "O",
                                                            "project": "P"}))
        bid = self.cli("new", "backlog", "--type", "bug", "--title", "Crash").stdout.split()[0]
        r = self.cli("backlog", "create", bid, "--sprint", "none")
        self.assertIn("found_in", r.stderr)

    def test_today_toggle(self):
        d = self.root / "daily"
        d.mkdir()
        (d / "2026-11-06.md").write_text("---\ntitle: T\ndate: 2026-11-06\n---\n\n## Today\n- [ ] [app-a] Do it (x)\n")
        self.assertEqual(self.cli("today", "--date", "2026-11-06", "--check", "[app-a] Do it (x)").returncode, 0)
        self.assertIn("- [x] [app-a] Do it (x)", (d / "2026-11-06.md").read_text())
        self.cli("today", "--date", "2026-11-06", "--check", "[app-a] Do it (x)", "--done", "false")
        self.assertIn("- [ ] [app-a] Do it (x)", (d / "2026-11-06.md").read_text())


class WorkTrackerTest(KbTestCase):
    """`kb work`: the built-in tracker in <scope>/work.json, shared with the app."""

    def work_file(self, scope="app-a"):
        return self.root / "projects" / scope / "work.json"

    def no_ado(self):
        env = {**self.env, "HOME": str(self.tmp)}
        env.pop("KB_ADO_PAT", None)
        return env

    def test_states_types_and_hierarchy(self):
        self.assertEqual(kb.canonical_state("pbi", "committed"), "Committed")
        self.assertEqual(kb.canonical_state("task", "todo"), "To Do")
        self.assertEqual(kb.canonical_state("task", "IN-progress"), "In Progress")
        with self.assertRaises(kb.WorkError):
            kb.canonical_state("pbi", "In Progress")
        with self.assertRaises(kb.WorkError):
            kb.canonical_state("task", "Committed")
        with self.assertRaises(kb.WorkError):
            kb.canonical_type("epic")
        data = kb.empty_work()
        f = kb.add_work_item(data, "feature", "F", now="2026-11-17T10:00:00Z")
        p = kb.add_work_item(data, "pbi", "P", parent=f["id"])
        b = kb.add_work_item(data, "bug", "B", parent=f["id"])
        t = kb.add_work_item(data, "task", "T", parent=b["id"])
        self.assertEqual((f["state"], t["state"], f["created"]), ("New", "To Do", "2026-11-17T10:00:00Z"))
        self.assertEqual([p["order"], b["order"], t["order"]], [1.0, 2.0, 1.0])
        for kind, parent in (("feature", f["id"]), ("pbi", p["id"]), ("bug", t["id"]), ("task", f["id"]), ("task", 99)):
            with self.assertRaises(kb.WorkError):
                kb.add_work_item(data, kind, "bad", parent=parent)
        with self.assertRaises(kb.WorkError):
            kb.update_work_item(data, t["id"], {"parent": f["id"]})
        kb.update_work_item(data, t["id"], {"parent": p["id"], "state": "in progress"})
        self.assertEqual((t["parent"], t["state"]), (p["id"], "In Progress"))
        self.assertEqual(data["next_id"], 5)

    def test_sprints_and_tree(self):
        data = kb.empty_work()
        data["sprints"] = [{"name": "Sprint 2", "start": "2026-12-01", "finish": "2026-12-14"},
                           {"name": "Sprint 1", "start": "2026-11-17", "finish": "2026-11-30"}]
        self.assertEqual(kb.current_sprint(data["sprints"], "2026-11-30")["name"], "Sprint 1")
        self.assertIsNone(kb.current_sprint(data["sprints"], "2026-11-16"))
        self.assertEqual(kb.resolve_sprint(data, "current", "2026-12-01"), "Sprint 2")
        self.assertEqual(kb.resolve_sprint(data, "sprint 1"), "Sprint 1")
        self.assertEqual(kb.resolve_sprint(data, "none"), "")
        with self.assertRaises(kb.WorkError):
            kb.resolve_sprint(data, "current", "2027-01-01")
        with self.assertRaises(kb.WorkError):
            kb.resolve_sprint(data, "Sprint 9")
        f = kb.add_work_item(data, "feature", "F")
        p = kb.add_work_item(data, "pbi", "P", parent=f["id"])
        loose = kb.add_work_item(data, "pbi", "Loose")
        t = kb.add_work_item(data, "task", "T", parent=p["id"])
        p["order"] = 5.0
        q = kb.add_work_item(data, "pbi", "Q", parent=f["id"])
        self.assertEqual(q["order"], 6.0)
        self.assertEqual([(d, i["id"]) for d, i in kb.work_tree(data["items"])],
                         [(0, f["id"]), (1, p["id"]), (2, t["id"]), (1, q["id"]), (0, loose["id"])])
        self.assertEqual([(d, i["id"]) for d, i in kb.work_tree([t, loose])], [(0, t["id"]), (0, loose["id"])])

    def test_add_list_show_set_remove(self):
        self.assertEqual(self.cli("work", "add", "feature", "Login").stdout, "created 1\n")
        r = self.cli("work", "add", "pbi", "Email login", "--parent", "1", "--description", "-", "--acceptance", "- works",
                     "--tags", "a, b", "--effort", "3", "--assignee", "Ann", stdin="Sign in by **email**.\n")
        self.assertEqual(r.stdout, "created 2\n", r.stderr)
        self.cli("work", "add", "task", "Form", "--parent", "2", "--state", "in progress")
        bad = self.cli("work", "add", "task", "Orphan", "--parent", "1")
        self.assertEqual(bad.returncode, 1)
        self.assertIn("a task's parent must be a pbi or bug", bad.stderr)
        self.assertIn("isn't a pbi state", self.cli("work", "add", "pbi", "X", "--state", "Doing").stderr)
        self.assertEqual(self.cli("work", "list").stdout,
                         "#1\tfeature\tNew\t\tLogin\n  #2\tpbi\tNew\t\tEmail login\n    #3\ttask\tIn Progress\t\tForm\n")
        item = json.loads(self.cli("work", "show", "2", "--json").stdout)
        self.assertEqual((item["description"], item["acceptance"], item["tags"], item["effort"], item["assignee"]),
                         ("Sign in by **email**.", "- works", ["a", "b"], 3, "Ann"))
        self.assertEqual((item["parent_title"], [c["id"] for c in item["children"]]), ("Login", [3]))
        self.assertIn("## Acceptance criteria", self.cli("work", "show", "2").stdout)

        self.cli("work", "sprint", "add", "Sprint 1", "--start", "2026-01-01", "--finish", "2099-12-31")
        self.assertIn("isn't a task state", self.cli("work", "set", "2", "3", "--state", "Committed").stderr)
        self.assertEqual(json.loads(self.cli("work", "show", "2", "--json").stdout)["state"], "New")
        self.assertEqual(self.cli("work", "set", "2", "--state", "done", "--sprint", "current", "--effort", "none").stdout,
                         "#2 updated\n")
        item = json.loads(self.cli("work", "show", "2", "--json").stdout)
        self.assertEqual((item["state"], item["sprint"], item["effort"]), ("Done", "Sprint 1", None))
        self.assertEqual(self.cli("work", "list").stdout, "#1\tfeature\tNew\t\tLogin\n#3\ttask\tIn Progress\t\tForm\n")
        self.assertIn("#2\tpbi\tDone", self.cli("work", "list", "--all").stdout)
        self.assertEqual(self.cli("work", "list", "--state", "done", "--sprint", "current").stdout,
                         "#2\tpbi\tDone\tSprint 1\tEmail login\n")
        self.assertEqual([i["id"] for i in json.loads(self.cli("work", "list", "--type", "task", "--json").stdout)["items"]], [3])

        self.assertIn("has children", self.cli("work", "remove", "2", "--delete").stderr)
        self.assertEqual(self.cli("work", "remove", "2").stdout, "#2 removed\n")
        self.assertEqual(self.cli("work", "remove", "3", "--delete").stdout, "#3 deleted\n")
        data = json.loads(self.work_file().read_text())
        self.assertEqual([(i["id"], i["state"]) for i in data["items"]], [(1, "New"), (2, "Removed")])
        self.assertEqual(data["next_id"], 4)
        self.assertEqual(self.cli("work", "add", "bug", "Crash").stdout, "created 4\n")

    def test_file_keeps_unknown_keys_and_key_order(self):
        self.work_file().write_text(json.dumps({
            "items": [{"id": 7, "type": "pbi", "title": "Old", "state": "New", "app_color": "red"}],
            "version": 1, "next_id": 8, "app_view": {"zoom": 2}, "use_sprints": True,
            "sprints": [{"name": "S", "start": "2026-11-01", "finish": "2026-11-14", "goal": "ship"}]}))
        self.cli("work", "set", "7", "--title", "New title")
        text = self.work_file().read_text()
        data = json.loads(text)
        self.assertEqual(list(data), ["version", "next_id", "use_sprints", "sprints", "items", "app_view"])
        self.assertEqual(data["app_view"], {"zoom": 2})
        self.assertEqual(data["sprints"][0]["goal"], "ship")
        self.assertEqual(list(data["items"][0]), [*kb.WORK_ITEM_KEYS, "app_color"])
        self.assertEqual((data["items"][0]["title"], data["items"][0]["app_color"]), ("New title", "red"))
        self.assertTrue(text.startswith('{\n  "version": 1,'))
        self.assertFalse(list(self.work_file().parent.glob(".*.tmp")))

    def test_tracker_mine_and_backlog_include_local_items_without_ado(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "local"}))
        self.cli("settings", "set", "tracker", json.dumps({"kind": "jira"}), "--project", "app-b")
        self.cli("work", "add", "feature", "F")
        self.cli("work", "add", "pbi", "Open", "--parent", "1", "--state", "approved")
        self.cli("work", "add", "bug", "Busy", "--state", "Committed")
        self.cli("work", "add", "pbi", "Finished", "--state", "Done")
        self.cli("work", "add", "pbi", "Dropped", "--state", "Removed")
        self.cli("work", "add", "task", "T1", "--parent", "2", "--state", "Done")
        self.cli("work", "add", "task", "T2", "--parent", "2")
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "tracker", "mine", "--json"],
                           cwd=self.repo_a, env=self.no_ado(), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        work = json.loads(r.stdout)
        self.assertEqual([(i["id"], i["type"], i["stage"], i["project"], i["url"], i["prs"]) for i in work["items"]],
                         [(2, "pbi", "not_started", "app-a", "", []), (3, "bug", "in_progress", "app-a", "", [])])
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "tracker", "backlog", "--json"],
                           cwd=self.repo_a, env=self.no_ado(), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = {i["id"]: i for i in json.loads(r.stdout)["items"]}
        self.assertEqual(sorted(rows), [2, 3, 4])
        self.assertEqual((rows[2]["tasks_done"], rows[2]["tasks_total"], rows[2]["scopes"]), (1, 2, ["app-a"]))
        self.assertEqual(rows[4]["stage"], "done")

    def test_tracker_points_jira_and_local_scopes_elsewhere(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "jira"}))
        self.assertEqual(json.loads(self.cli("tracker", "show").stdout), {"kind": "jira"})
        for args in (("items",), ("sprints",), ("task-state", "5", "--state", "Done")):
            r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "tracker", *args],
                               cwd=self.repo_a, env=self.no_ado(), capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertIn("app-a tracks work in Jira; use Claude's Jira connector", r.stderr)
        self.cli("settings", "set", "tracker", json.dumps({"kind": "local"}))
        self.assertIn("kb work", self.cli("tracker", "features").stderr)


class SplitLayoutTest(KbTestCase):
    """The split layout: shared/ for what spans projects, <scope>/ private, <repo>/knowledgebase/ for the team."""

    def migrate(self):
        self.cli("new", "decision", "--title", "Use Room", "--body", "Because.")
        self.cli("new", "followup", "--title", "Ask design", "--field", "kind=question")
        (self.root / "projects" / "app-a" / "settings.json").write_text("{}")
        (self.root / "reminders").mkdir()
        (self.root / "reminders" / "r.md").write_text("---\ntitle: R\n---\n")
        dest = self.tmp / "kb2"
        dry = self.cli("layout", "migrate", "--to", str(dest))
        self.assertIn("Nothing copied", dry.stdout)
        self.assertFalse(dest.exists())
        env = {**self.env, "HOME": str(self.tmp)}
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "layout", "migrate", "--to", str(dest), "--yes"],
                           cwd=self.repo_a, env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.env["KB_ROOT"] = str(dest)
        os.environ["KB_ROOT"] = str(dest)
        return dest

    def test_migrate_splits_team_and_private(self):
        dest = self.migrate()
        team = self.repo_a / "knowledgebase"
        self.assertEqual(len(list((team / "decisions").glob("*.md"))), 1)
        self.assertEqual(len(list((team / "followups").glob("*.md"))), 1)
        self.assertTrue((dest / "app-a" / "settings.json").is_file())
        self.assertTrue((dest / "shared" / "kb.json").is_file())
        self.assertTrue((dest / "shared" / "reminders" / "r.md").is_file())
        self.assertTrue((self.root / "projects" / "app-a" / "decisions").is_dir(), "the old KB stays")
        # The scope without a repo keeps everything private.
        self.assertFalse((self.tmp / "repos" / "shared").exists())

    def test_split_reads_both_and_writes_by_section(self):
        dest = self.migrate()
        ids = self.cli("list", "--project", "app-a").stdout
        self.assertIn("use-room", ids)
        self.assertIn("ask-design", ids)
        new = self.cli("new", "fact", "--title", "Min SDK is 26").stdout.split()[0]
        self.assertTrue(list((self.repo_a / "knowledgebase" / "facts").glob("*min-sdk-is-26.md")), new)
        disc = self.cli("new", "discussion", "--title", "Login flow").stdout.split()[0]
        self.assertTrue(list((dest / "app-a" / "discussions").glob("*login-flow.md")), disc)
        self.assertIn("Use Room", self.cli("show", ids.split()[0] if "use-room" in ids.split()[0] else
                                           next(x for x in ids.split() if "use-room" in x)).stdout)
        show = self.cli("layout", "show").stdout
        self.assertIn("layout: split", show)
        self.assertIn(str(self.repo_a / "knowledgebase"), show)


    def test_session_in_a_worktree_writes_to_its_own_checkout(self):
        self.migrate()
        g = lambda *a, cwd=self.repo_a: subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True, check=True)
        shutil.rmtree(self.repo_a / "worktrees")
        g("init", "-q", "-b", "main")
        g("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
        wt = self.tmp / "wt-feature"
        g("worktree", "add", "-q", "-b", "feature", str(wt))
        r = self.cli("new", "fact", "--project", "app-a", "--title", "Feature fact", cwd=wt)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(list((wt / "knowledgebase" / "facts").glob("*feature-fact.md")))
        self.assertFalse(list((self.repo_a / "knowledgebase" / "facts").glob("*feature-fact.md")))


class SourcesTest(KbTestCase):
    def test_builtins_project_and_global_and_separation(self):
        self.cli("sources", "add", "--kind", "url", "--title", "Docs A", "--use-for", "a docs",
                 "--config", "url=https://example.com")
        self.cli("sources", "add", "--kind", "folder", "--title", "B notes", "--use-for", "b",
                 "--config", f"path={self.repo_b}", cwd=self.repo_b)
        self.cli("sources", "add", "--global", "--kind", "teams", "--title", "Teams", "--use-for", "chat")
        ids_a = [s["id"] for s in json.loads(self.cli("sources", "list", "--json").stdout)]
        self.assertEqual(ids_a[:3], ["kb", "code", "related:shared"])
        self.assertIn("docs-a", ids_a)
        self.assertIn("teams", ids_a)
        self.assertNotIn("b-notes", ids_a)
        self.assertEqual(self.cli("sources", "remove", "docs-a").returncode, 0)
        self.assertNotIn("docs-a", self.cli("sources", "list").stdout)

    def test_command_and_folder_sources_run(self):
        (self.repo_a / "notes.md").write_text("the export format is taken after retry")
        sid = self.cli("sources", "add", "--kind", "command", "--title", "Echo", "--use-for", "x",
                       "--config", "run=echo got {query}").stdout.strip()
        r = self.cli("sources", "test", sid, "--query", "it's raw")
        self.assertEqual(r.stdout.strip(), "got it's raw")
        hit = self.cli("sources", "test", "code", "--query", "export format")
        self.assertIn("notes.md", hit.stdout)

    def test_connector_kinds_say_to_test_with_claude(self):
        self.cli("sources", "add", "--global", "--kind", "outlook", "--title", "Mail", "--use-for", "m")
        r = self.cli("sources", "test", "mail", "--query", "x")
        self.assertEqual(r.returncode, 3)


class DeleteTest(KbTestCase):
    def test_deleting_a_superseding_decision_restores_the_old_one_and_unhooks_links(self):
        old = self.cli("new", "decision", "--title", "Use A", "--date", "2026-01-01").stdout.split()[0]
        meeting = self.cli("new", "meeting", "--title", "Sync", "--date", "2026-02-01").stdout.split()[0]
        new = self.cli("new", "decision", "--title", "Use B", "--supersedes", old, "--source", meeting).stdout.split()[0]
        fu = self.cli("new", "followup", "--title", "Q", "--field", f"raised_in={meeting}").stdout.split()[0]

        dry = self.cli("delete", new, "--dry-run")
        self.assertIn("back in force", dry.stdout)
        self.assertIsNotNone(kb.find_entry(self.root, new))

        self.assertEqual(self.cli("delete", new).returncode, 0)
        self.assertIsNone(kb.find_entry(self.root, new))
        o = kb.find_entry(self.root, old)
        self.assertEqual((o.status, o.get("superseded_by")), ("active", ""))

        self.cli("delete", meeting)
        self.assertEqual(kb.find_entry(self.root, fu).get("raised_in"), "")
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")

    def test_deleting_an_old_decision_drops_it_from_supersedes(self):
        old = self.cli("new", "decision", "--title", "Use A", "--date", "2026-01-01").stdout.split()[0]
        new = self.cli("new", "decision", "--title", "Use B", "--supersedes", old).stdout.split()[0]
        self.cli("delete", old)
        self.assertEqual(kb.find_entry(self.root, new).get("supersedes"), "")
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")


class CalendarTest(KbTestCase):
    def setUp(self):
        super().setUp()
        import datetime as dt
        self.today = dt.date.today().isoformat()
        self.yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()
        self.week_ago = (dt.date.today() - dt.timedelta(days=7)).isoformat()

    def sync(self, events, start=None, end=None):
        start = start or self.today
        r = self.cli("calendar", "import", "--from", start, "--to", end or start,
                     stdin=json.dumps({"events": events}))
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def meetings(self):
        return {str(e.get("calendar_id")): e for e in kb.all_entries(self.root)
                if e.section == "meetings" and e.get("calendar_id")}

    def ev(self, id, title, start="10:00", end="11:00", date=None, **extra):
        date = date or self.today
        return {"id": id, "title": title, "start": f"{date}T{start}:00", "end": f"{date}T{end}:00", **extra}

    def test_new_events_become_scheduled_meetings_in_the_default_project(self):
        out = self.sync([self.ev("e1", "Design sync", attendees=["Ann", "Bo"], body="Agenda: upload"),
                         self.ev("e2", "Lunch"), {"id": "e3", "title": "Holiday", "start": self.today, "all_day": True}])
        self.assertIn("1 new", out)
        m = self.meetings()["e1"]
        self.assertEqual((m.project, m.status, m.get("start"), m.get("end")), ("shared", "scheduled", "10:00", "11:00"))
        self.assertEqual(m.get("attendees"), ["Ann", "Bo"])
        self.assertTrue(m.get("project_guessed"))
        self.assertIn("Agenda: upload", m.body)
        self.assertNotIn("e2", self.meetings())

    def test_hints_and_earlier_occurrences_route_the_meeting(self):
        self.cli("settings", "set", "--project", "app-b", "conventions.meeting_hints", '["android"]')
        old = self.cli("new", "meeting", "--project", "app-a", "--title", "Sprint 24 Retrospective",
                       "--date", self.week_ago).stdout.split()[0]
        self.sync([self.ev("r", "Sprint 25 Retrospective"), self.ev("a", "Android refinement")])
        m = self.meetings()
        self.assertEqual((m["r"].project, m["r"].get("previous")), ("app-a", old))
        self.assertEqual(m["a"].project, "app-b")
        self.assertFalse(m["a"].get("project_guessed"))

    def test_changes_update_the_file_and_keep_the_users_title_and_work(self):
        self.sync([self.ev("e1", "Sync")])
        m = self.meetings()["e1"]
        m.set("title", "My own title")
        m.body = m.body.replace("## Questions\n", "## Questions\n- [ ] Ask about X\n")
        m.save()
        out = self.sync([self.ev("e1", "Sync (moved)", start="14:00", end="15:00")])
        self.assertIn("1 updated", out)
        m = self.meetings()["e1"]
        self.assertEqual((m.title, m.get("start"), m.get("calendar_title")), ("My own title", "14:00", "Sync (moved)"))
        self.assertIn("Ask about X", m.body)
        self.assertIn("0 new", self.sync([self.ev("e1", "Sync (moved)", start="14:00", end="15:00")]))

    def test_cancelled_or_vanished_events_are_cancelled_and_come_back(self):
        self.sync([self.ev("e1", "A"), self.ev("e2", "B")])
        self.sync([self.ev("e1", "A", cancelled=True)])
        m = self.meetings()
        self.assertEqual((m["e1"].status, m["e2"].status), ("cancelled", "cancelled"))
        self.sync([self.ev("e1", "A"), self.ev("e2", "B")])
        self.assertEqual(self.meetings()["e1"].status, "scheduled")

    def test_a_held_meeting_is_never_cancelled(self):
        self.sync([self.ev("e1", "A")])
        m = self.meetings()["e1"]
        m.set("status", "live")
        m.body = m.body.replace("## Raw notes\n", "## Raw notes\nWe agreed on B\n")
        m.save()
        self.sync([self.ev("e1", "A", cancelled=True)])
        self.sync([])
        self.assertEqual(self.meetings()["e1"].status, "live")

    def test_past_untouched_mirrors_are_pruned_but_prepared_ones_stay(self):
        self.sync([self.ev("p1", "Standup"), self.ev("p2", "Review"),
                   self.ev("p3", "Old", date=self.yesterday)])
        for cid, m in self.meetings().items():
            m.set("date", self.yesterday)
            if cid == "p2":
                m.body = m.body.replace("## Questions\n", "## Questions\n- [ ] Q\n")
            m.save()
        out = self.sync([], start=self.today)
        self.assertIn("1 pruned", out)
        self.assertEqual(set(self.meetings()), {"p2"})
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")


class MoveTest(KbTestCase):
    def test_move_repoints_references_and_clears_the_guess(self):
        meeting = self.cli("new", "meeting", "--project", "shared", "--cross-project", "--title", "Sync",
                           "--field", "project_guessed=true").stdout.split()[0]
        fu = self.cli("new", "followup", "--title", "Q", "--field", f"raised_in={meeting}").stdout.split()[0]
        r = self.cli("move", meeting, "--project", "app-a")
        self.assertEqual(r.returncode, 0, r.stderr)
        new = r.stdout.split()[0]
        self.assertTrue(new.startswith("app-a/meetings/"))
        self.assertIsNone(kb.find_entry(self.root, meeting))
        self.assertFalse(kb.find_entry(self.root, new).get("project_guessed"))
        self.assertEqual(kb.find_entry(self.root, fu).get("raised_in"), new)
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")


class ReminderEmailTest(KbTestCase):
    def test_reminders_add_dedupe_and_lifecycle(self):
        r = self.cli("reminder", "add", "--title", "Finish GDPR training", "--due", "2026-11-12",
                     "--source", "email:abc", "--from", "HR", "--from-domain", "example.com", "--proposed")
        rid = r.stdout.split()[0]
        self.assertEqual(rid, "reminders/finish-gdpr-training")
        again = self.cli("reminder", "add", "--title", "Other", "--due", "2026-11-13", "--source", "email:abc")
        self.assertIn("exists", again.stdout)
        self.assertEqual(len(list((self.root / "reminders").glob("*.md"))), 1)
        self.assertIn("proposed", self.cli("reminder", "list").stdout)
        self.cli("reminder", "accept", rid)
        self.cli("reminder", "due", rid, "2026-11-20")
        self.cli("reminder", "done", rid)
        e = kb.read_reminder(self.root / "reminders" / "finish-gdpr-training.md")
        self.assertEqual((e.status, e.get("due"), e.get("from")), ("done", "2026-11-20", "HR"))
        self.assertEqual(self.cli("reminder", "list").stdout.strip(), "")
        self.assertNotEqual(self.cli("reminder", "add", "--title", "x", "--due", "soon").returncode, 0)

    def test_reminder_without_a_due_date(self):
        rid = self.cli("reminder", "add", "--title", "Read the team handbook").stdout.split()[0]
        e = kb.read_reminder(self.root / "reminders" / "read-the-team-handbook.md")
        self.assertEqual((e.get("due"), e.status), ("", "open"))
        self.cli("reminder", "add", "--title", "Dated", "--due", "2000-01-01")
        out = self.cli("reminder", "list").stdout.splitlines()
        self.assertTrue(out[0].startswith("2000-01-01 open OVERDUE"))
        self.assertEqual(out[1], f"no-date open {rid}: Read the team handbook")
        self.cli("reminder", "due", rid, "2026-12-01")
        self.cli("reminder", "due", rid, "none")
        self.assertEqual(kb.read_reminder(self.root / "reminders" / "read-the-team-handbook.md").get("due"), "")

    def test_email_state_scanned_and_ignore(self):
        st = json.loads(self.cli("email", "state").stdout)
        self.assertIn("medium.com", st["ignore"])
        self.assertTrue(st["since"])
        self.cli("email", "scanned", "--at", "2026-11-09T10:00")
        self.cli("email", "ignore", "news@udemy.com")
        st = json.loads(self.cli("email", "state").stdout)
        self.assertEqual((st["since"], st["last_scan"]), ("2026-11-09T10:00", "2026-11-09T10:00"))
        self.assertIn("udemy.com", st["ignore"])


class GoalTest(KbTestCase):
    def test_goal_lifecycle_and_quiet_context(self):
        self.assertNotIn("Side goals", kb.build_context(self.root, self.repo_a))
        gid = self.cli("goal", "add", "--title", "Become a tech lead", "--horizon", "by end of 2027",
                       "--why", "Next career step").stdout.split()[0]
        self.assertEqual(gid, "goals/become-a-tech-lead")
        ctx = kb.build_context(self.root, self.repo_a)
        self.assertIn("### Side goals", ctx)
        self.assertIn("`goals/become-a-tech-lead` Become a tech lead (by end of 2027)", ctx)
        self.cli("goal", "log", gid, "Led the retro on review latency", "--date", "2026-11-09")
        self.cli("goal", "log", gid, "Wrote the retry design note", "--date", "2026-11-10")
        body = kb.find_goal(self.root, gid).body
        self.assertLess(body.index("2026-11-10"), body.index("2026-11-09"))
        self.assertIn("Next career step", kb.body_section(body, "Why"))
        self.cli("goal", "status", gid, "paused")
        self.assertNotIn("Side goals", kb.build_context(self.root, self.repo_a))
        self.assertIn("[paused]", self.cli("goal", "list", "--all").stdout)

    def test_proposed_progress_skips_what_is_already_there(self):
        gid = self.cli("goal", "add", "--title", "Lead more").stdout.split()[0]
        self.cli("goal", "log", gid, "Ran the retro", "--date", "2026-11-09")
        self.cli("goal", "propose", gid, "Led the  pairing bug review", "--date", "2026-11-12")
        self.assertIn("already there", self.cli("goal", "propose", gid, "Ran the retro").stdout)
        self.assertIn("already there", self.cli("goal", "propose", gid, "led the pairing bug review").stdout)
        g = kb.find_goal(self.root, gid)
        self.assertEqual(kb.body_section(g.body, "Proposed progress"), "- 2026-11-12: Led the pairing bug review")
        self.assertLess(g.body.index("## Proposed progress"), g.body.index("## Progress"))
        self.assertEqual(g.get("progress_scanned"), kb.dt.date.today().isoformat())
        self.assertIn("1 proposed progress", self.cli("goal", "list").stdout)



class IdeaTest(KbTestCase):
    def test_idea_notes_and_status(self):
        r = self.cli("new", "idea", "--title", "Offline sync for measurements", "--summary", "Queue uploads",
                     "--body", "Keep measurements when offline.")
        self.assertEqual(r.returncode, 0, r.stderr)
        iid = r.stdout.split()[0]
        self.assertIn("/ideas/", iid)
        self.assertIn("Offline sync", self.cli("idea", "list").stdout)
        self.cli("idea", "note", iid, "--text", "Use WorkManager")
        self.cli("idea", "note", iid, "--kind", "question", "--text", "How long to keep them?")
        e = kb.find_entry(self.root, iid)
        self.assertEqual(e.status, "exploring")
        self.assertIn("- Use WorkManager", kb.body_section(e.body, "Brainstorm"))
        self.assertIn("- [ ] How long to keep them?", kb.body_section(e.body, "Open questions"))
        self.assertIn("Keep measurements when offline.", kb.body_section(e.body, "The idea"))
        self.cli("idea", "status", iid, "shelved")
        self.assertNotIn("Offline sync", self.cli("idea", "list").stdout)
        self.assertIn("shelved", self.cli("idea", "list", "--all").stdout)


class ResearchTest(KbTestCase):
    def test_research_notes_summary_and_status(self):
        r = self.cli("new", "research", "--title", "Background uploads on iOS", "--field", "for=wi:1234",
                     "--body", "Can uploads run in the background?")
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = r.stdout.split()[0]
        self.assertIn("/research/", rid)
        e = kb.find_entry(self.root, rid)
        self.assertEqual((e.status, e.get("for")), ("open", "wi:1234"))
        self.assertIn("Can uploads run in the background?", kb.body_section(e.body, "Question"))
        self.cli("research", "note", rid, "--text", "URLSession background uploads survive a kill")
        self.cli("research", "note", rid, "--kind", "question", "--text", "Does the BFF take chunks?")
        self.cli("research", "note", rid, "--kind", "source", "--text", "https://developer.apple.com")
        self.assertIn("Background uploads", self.cli("research", "list", "--for", "#1234").stdout)
        self.assertEqual(self.cli("research", "list", "--for", "#99").stdout, "")
        r = self.cli("research", "summary", rid, "--takeaway", "Use a background URLSession",
                     "--takeaway", "Uploads must be files", stdin="Yes, with a background URLSession.")
        self.assertEqual(r.returncode, 0, r.stderr)
        e = kb.find_entry(self.root, rid)
        self.assertEqual(e.status, "review")
        self.assertIn("- URLSession background uploads survive a kill", kb.body_section(e.body, "Findings"))
        self.assertIn("- [ ] Does the BFF take chunks?", kb.body_section(e.body, "Open questions"))
        self.assertEqual(kb.body_section(e.body, "Summary"), "Yes, with a background URLSession.")
        self.assertEqual(kb.body_section(e.body, "Takeaways"), "- Use a background URLSession\n- Uploads must be files")
        self.assertTrue(e.body.index("## Summary") < e.body.index("## Takeaways"))
        self.cli("research", "status", rid, "done", "--transferred", "wi:1234")
        e = kb.find_entry(self.root, rid)
        self.assertEqual((e.status, e.get("transferred_to")), ("done", "wi:1234"))
        self.assertNotIn("Background uploads", self.cli("research", "list").stdout)
        self.assertIn("done", self.cli("research", "list", "--all").stdout)

    def test_tracker_note_adds_to_a_local_items_description(self):
        self.cli("settings", "set", "tracker", json.dumps({"kind": "local"}))
        self.cli("work", "add", "pbi", "Uploads", "--description", "Upload samples.")
        r = self.cli("tracker", "note", "1", "--scope", "app-a", "--heading", "Research: Uploads",
                     stdin="- Use a background URLSession (see app-a/research/2026-11-20-x)\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        item = json.loads((self.root / "projects" / "app-a" / "work.json").read_text())["items"][0]
        self.assertEqual(item["description"], "Upload samples.\n\n### Research: Uploads\n\n- Use a background URLSession\n")
        r = self.cli("tracker", "note", "1", "--scope", "app-a", "--comment", stdin="- x")
        self.assertNotEqual(r.returncode, 0)
        r = self.cli("tracker", "note", "1", "--scope", "app-a", stdin="- see ~/notes/x.md")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("local paths", r.stderr)


class ProjectDocsTest(KbTestCase):
    def test_scan_add_draft_and_clear(self):
        subprocess.run(["git", "init", "-q", str(self.repo_b)], check=True)
        (self.repo_b / "docs").mkdir()
        (self.repo_b / "docs" / "arch.md").write_text("# The architecture\n\nBLE talks to the BFF.\n")
        (self.repo_b / "README.md").write_text("Readme\n")
        (self.repo_b / "node_modules" / "x").mkdir(parents=True)
        (self.repo_b / "node_modules" / "x" / "README.md").write_text("# no\n")
        scan = json.loads(self.cli("docs", "scan", "--scope", "app-b", "--json").stdout)["docs"]
        self.assertEqual([d["path"] for d in scan], ["README.md", "docs/arch.md"])
        self.assertEqual(scan[1]["title"], "The architecture")
        self.assertEqual(self.cli("docs", "add", "docs/arch.md", "--scope", "app-b").returncode, 0)
        self.assertNotEqual(self.cli("docs", "add", "../escape.md", "--scope", "app-b").returncode, 0)

        self.cli("docs", "draft", "docs/arch.md", "--scope", "app-b", stdin="# The architecture\n\nBLE talks to the BFF v2.\n")
        self.cli("docs", "draft", "docs/new.md", "--scope", "app-b", stdin="# New\n")
        docs = {d["path"]: d for d in json.loads(self.cli("docs", "list", "--scope", "app-b", "--json").stdout)["docs"]}
        self.assertEqual((docs["docs/arch.md"]["draft"], docs["docs/new.md"]["draft"]), ("edited", "new"))
        self.assertFalse(docs["docs/arch.md"]["stale"])
        self.assertIn("v2", Path(docs["docs/arch.md"]["file"]).read_text())
        self.assertIn("v2", (self.repo_b / "docs" / "arch.md").read_text() + self.cli("docs", "show", "docs/arch.md", "--scope", "app-b").stdout)
        self.assertNotIn("v2", (self.repo_b / "docs" / "arch.md").read_text())
        self.assertIn("+BLE talks to the BFF v2.", self.cli("docs", "diff", "--scope", "app-b").stdout)

        (self.repo_b / "docs" / "arch.md").write_text("# The architecture\n\nChanged in the repo.\n")
        docs = {d["path"]: d for d in json.loads(self.cli("docs", "list", "--scope", "app-b", "--json").stdout)["docs"]}
        self.assertTrue(docs["docs/arch.md"]["stale"])

        self.cli("docs", "discard", "docs/new.md", "--scope", "app-b")
        self.cli("docs", "saved", "docs/arch.md", "--scope", "app-b")
        docs = json.loads(self.cli("docs", "list", "--scope", "app-b", "--json").stdout)["docs"]
        self.assertEqual([(d["path"], d["draft"]) for d in docs], [("docs/arch.md", None)])
        self.assertIn("docs/arch.md", kb.build_context(self.root, self.repo_b))


class FactChangeTest(KbTestCase):
    def fact(self, title="BLE MTU is 247", body="The firmware negotiates 247 bytes."):
        r = self.cli("new", "fact", "--title", title, "--summary", "MTU", "--date", "2026-01-01",
                     "--body-stdin", stdin=body)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.split()[0]

    def challenge(self, fid, by="app-a/meetings/2026-11-09-sync", body=None):
        args = ["fact", "challenge", fid, "--by", by, "--question", "Is it 512 now?"]
        r = self.cli(*args, *(["--body-stdin"] if body is not None else []), stdin=body or "")
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.split()[0]

    def test_challenge_creates_one_pending_change_per_source(self):
        fid = self.fact()
        c1 = self.challenge(fid, body="The firmware negotiates 512 bytes.")
        change = kb.find_entry(self.root, c1)
        self.assertEqual((change.get("updates"), change.get("proposed_section"), change.get("question")),
                         (fid, "facts", "Is it 512 now?"))
        self.assertIn("512", change.body)
        again = self.challenge(fid, body="Still 512.")
        self.assertEqual(again, c1)
        self.assertIn("Still 512", kb.find_entry(self.root, c1).body)
        self.challenge(fid, by="session:abc")
        listed = self.cli("fact", "changes", "--fact", fid).stdout.strip().splitlines()
        self.assertEqual(len(listed), 2)
        self.assertEqual(listed[0].split("\t")[1], fid)
        self.assertIn(fid, self.cli("inbox", "list").stdout)
        ctx = kb.build_context(self.root, self.repo_a)
        self.assertIn("⚠ may have changed", ctx)
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")

    def test_challenge_needs_a_fact(self):
        d = self.cli("new", "decision", "--title", "Not a fact").stdout.split()[0]
        r = self.cli("fact", "challenge", d, "--by", "x", "--question", "q")
        self.assertNotEqual(r.returncode, 0)

    def test_update_rewrites_the_same_file(self):
        fid = self.fact()
        path = kb.find_entry(self.root, fid).path
        self.cli("new", "meeting", "--title", "Sync", "--date", "2026-11-09")
        c = self.challenge(fid, body="The firmware negotiates 512 bytes.")
        r = self.cli("fact", "resolve", c, "--update")
        self.assertEqual(r.returncode, 0, r.stderr)
        f = kb.find_entry(self.root, fid)
        self.assertEqual(f.path, path)
        self.assertIn("512", f.body)
        self.assertEqual(f.date, kb.dt.date.today().isoformat())
        self.assertEqual(f.get("source"), "app-a/meetings/2026-11-09-sync")
        self.assertEqual([k for k in dict(f.fields) if k in kb.INBOX_ONLY_FIELDS], [])
        self.assertIsNone(kb.find_entry(self.root, c))
        self.assertEqual(len(list(path.parent.iterdir())), 1)
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")

    def test_keep_only_marks_it_verified(self):
        fid = self.fact()
        c = self.challenge(fid, body="Different text")
        self.cli("fact", "resolve", c, "--keep")
        f = kb.find_entry(self.root, fid)
        self.assertEqual(f.date, kb.dt.date.today().isoformat())
        self.assertIn("247", f.body)
        self.assertIsNone(kb.find_entry(self.root, c))

    def test_remove_deletes_the_fact_and_every_pending_change(self):
        fid = self.fact()
        c1 = self.challenge(fid)
        c2 = self.challenge(fid, by="session:abc")
        r = self.cli("fact", "resolve", c1, "--remove")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(kb.find_entry(self.root, fid))
        self.assertIsNone(kb.find_entry(self.root, c2))
        self.assertEqual(self.cli("lint").stdout.strip(), "ok")

    def test_inbox_approve_of_a_change_updates_in_place(self):
        fid = self.fact()
        c = self.challenge(fid, by="session:abc", body="512 now.")
        out = self.cli("inbox", "approve", c).stdout.split()
        self.assertEqual(out[0], fid)
        self.assertEqual(len(list((self.root / "projects" / "app-a" / "facts").iterdir())), 1)
        self.assertIn("512 now", kb.find_entry(self.root, fid).body)
        self.assertNotEqual(kb.find_entry(self.root, fid).get("source"), "session:abc")

    def test_deleting_a_fact_drops_its_pending_changes(self):
        fid = self.fact()
        c = self.challenge(fid)
        self.cli("delete", fid)
        self.assertIsNone(kb.find_entry(self.root, c))


class ScanTest(KbTestCase):
    def setUp(self):
        super().setUp()
        self.scans = self.tmp / "scans"
        self.env["KB_SCANS_DIR"] = str(self.scans)
        os.environ["KB_SCANS_DIR"] = str(self.scans)

    def tearDown(self):
        os.environ.pop("KB_SCANS_DIR", None)

    def ok(self, *args, stdin=""):
        r = self.cli(*args, stdin=stdin)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def test_findings_wait_for_the_user_then_apply(self):
        run = self.ok("scan", "new", "--scope", "app-a", "--kinds", "facts,decisions,followups,overview")
        f1 = self.ok("scan", "found", "--run", run, "--kind", "facts", "--title", "Min SDK is 26",
                     "--summary", "Android min SDK 26.", "--source", f"{self.repo_a}/app/build.gradle:12",
                     "--body", "minSdk 26 in app/build.gradle.")
        self.assertEqual(f1, "f1")
        dup = self.cli("scan", "found", "--run", run, "--kind", "facts", "--title", "min sdk is 26")
        self.assertNotEqual(dup.returncode, 0)
        self.assertIn("already found", dup.stderr)
        wrong = self.cli("scan", "found", "--run", run, "--kind", "backlog", "--title", "X")
        self.assertNotEqual(wrong.returncode, 0)
        f2 = self.ok("scan", "found", "--run", run, "--kind", "decisions", "--title", "Use Room", "--date", "2025-03-01",
                     "--body", "## Decision\nRoom.\n\n## Why\nFrom commit abc.")
        f3 = self.ok("scan", "found", "--run", run, "--kind", "followups", "--title", "Who owns the BLE retry?",
                     "--followup-kind", "question")
        f4 = self.ok("scan", "found", "--run", run, "--kind", "overview", "--title", "App A", "--summary", "The app.",
                     "--body", "App A measures things.")
        self.assertEqual(self.ok("scan", "list").count("4 found, 4 to review"), 1)
        self.assertEqual(list((self.root / "projects" / "app-a" / "facts").glob("*.md")), [])
        out = self.ok("scan", "apply", "--run", run, f1, f2, f4)
        self.assertIn("f1\tapp-a/facts/min-sdk-is-26", out)
        fact = (self.root / "projects" / "app-a" / "facts" / "min-sdk-is-26.md").read_text()
        self.assertIn("app/build.gradle:12", fact)
        self.assertNotIn(str(self.repo_a), fact)
        self.assertTrue((self.root / "projects" / "app-a" / "decisions" / "2025-03-01-use-room.md").is_file())
        self.assertIn("App A measures things.", (self.root / "projects" / "app-a" / "overview.md").read_text())
        self.ok("scan", "dismiss", "--run", run, f3)
        st = json.loads(self.ok("scan", "show", "--run", run, "--json"))
        self.assertEqual({k: v["status"] for k, v in st["findings"].items()},
                         {"f1": "applied", "f2": "applied", "f3": "dismissed", "f4": "applied"})
        again = self.cli("scan", "found", "--run", run, "--kind", "facts", "--title", "Min SDK is 26 ")
        self.assertIn("already", again.stderr)
        self.ok("scan", "done", "--run", run, "--note", "4 things")
        self.assertNotEqual(self.cli("scan", "found", "--run", run, "--kind", "facts", "--title", "Late").returncode, 0)

    def test_a_known_fact_is_updated_in_place(self):
        old = self.ok("new", "fact", "--title", "Min SDK is 24", "--body", "24.").split()[0]
        run = self.ok("scan", "new", "--scope", "app-a", "--kinds", "facts")
        known = self.cli("scan", "found", "--run", run, "--kind", "facts", "--title", "Min SDK is 24")
        self.assertIn(f"--updates {old}", known.stderr)
        fid = self.ok("scan", "found", "--run", run, "--kind", "facts", "--title", "Min SDK is 26", "--updates", old,
                      "--body", "26 since the BLE change.")
        self.ok("scan", "apply", "--run", run, fid)
        facts = list((self.root / "projects" / "app-a" / "facts").glob("*.md"))
        self.assertEqual(len(facts), 1)
        self.assertIn("26 since the BLE change.", facts[0].read_text())
        self.assertIn("title: Min SDK is 26", facts[0].read_text())

    def test_bad_ids_and_kinds(self):
        self.assertNotEqual(self.cli("scan", "new", "--scope", "nope").returncode, 0)
        self.assertNotEqual(self.cli("scan", "new", "--scope", "app-a", "--kinds", "gossip").returncode, 0)
        self.assertNotEqual(self.cli("scan", "progress", "--run", "../x", "hi").returncode, 0)


class CrewTest(KbTestCase):
    LEAD = "aaaa1111-0000-4000-8000-000000000001"
    MEMBER = "bbbb2222-0000-4000-8000-000000000002"
    OVER = "cccc3333-0000-4000-8000-000000000003"
    SOLO = "dddd4444-0000-4000-8000-000000000004"

    def setUp(self):
        super().setUp()
        self.crew = self.tmp / "crew"
        self.crew.mkdir()
        self.env["KB_CREW_DIR"] = str(self.crew)
        os.environ["KB_CREW_DIR"] = str(self.crew)
        now = kb.iso_now()
        sess = [
            {"id": self.OVER, "title": "Overview", "role": "overseer", "lead": None, "state": "idle"},
            {"id": self.LEAD, "title": "Auth feature", "role": "lead", "lead": None, "project": "app-a",
             "state": "working", "activity": "Editing Login.kt", "strategy": "auto-crew"},
            {"id": self.MEMBER, "title": "Auth tests", "role": "member", "lead": self.LEAD, "state": "idle",
             "model": "haiku"},
            {"id": self.SOLO, "title": "Auth docs", "role": "solo", "lead": None, "state": "stopped"},
        ]
        self.state = {"updated": now, "sessions": [{**s, "updated": now} for s in sess]}
        (self.crew / "state.json").write_text(json.dumps(self.state))

    def tearDown(self):
        os.environ.pop("KB_CREW_DIR", None)
        os.environ.pop("KB_SESSION_ID", None)

    def orders(self):
        files = sorted((self.crew / "orders").glob("*.json"))
        return [json.loads(f.read_text()) for f in files]

    def test_sync_asks_the_app_and_waits_for_its_answer(self):
        import threading

        def app():
            for _ in range(50):
                orders = list((self.crew / "orders").glob("*.json"))
                if orders:
                    order = json.loads(orders[0].read_text())
                    (self.crew / "sync").mkdir(exist_ok=True)
                    (self.crew / "sync" / f"{order['id']}.json").write_text(json.dumps({"results": [
                        {"what": "calendar", "ok": True, "line": f"calendar: 1 updated ({order['range_from']})"}]}))
                    return
                time.sleep(0.1)
        t = threading.Thread(target=app)
        t.start()
        r = self.cli("sync", "meetings", "--from", "2026-11-23", "--to", "2026-11-29", "--timeout", "10")
        t.join()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "calendar: 1 updated (2026-11-23)\n")
        self.assertEqual(list((self.crew / "sync").glob("*.json")), [])

    def test_sync_without_the_app_says_what_to_do_instead(self):
        (self.crew / "state.json").write_text(json.dumps({"updated": "2020-01-01T00:00:00Z", "sessions": []}))
        r = self.cli("sync", "calendar", "prs")
        self.assertEqual(r.returncode, 1)
        self.assertIn("kb:calendar skill", r.stdout)
        self.assertIn("read Azure DevOps live", r.stdout)
        self.assertEqual(kb.sync_kinds(["all"]), ["calendar", "tracker", "prs"])
        self.assertNotEqual(self.cli("sync", "weather").returncode, 0)

    def test_refs(self):
        os.environ["KB_SESSION_ID"] = self.MEMBER
        r = lambda ref: kb.crew_session(self.state, ref)["id"]
        self.assertEqual(r("aaaa1"), self.LEAD)
        self.assertEqual(r(self.SOLO), self.SOLO)
        self.assertEqual(r("me"), self.MEMBER)
        self.assertEqual(r("lead"), self.LEAD)
        self.assertEqual(r("overseer"), self.OVER)
        self.assertEqual(r("auth TESTS"), self.MEMBER)
        self.assertEqual(r("docs"), self.SOLO)
        with self.assertRaises(SystemExit) as e:
            r("auth")
        self.assertIn("several", str(e.exception.code))
        with self.assertRaises(SystemExit):
            r("nothing like it")
        os.environ["KB_SESSION_ID"] = self.LEAD
        self.assertEqual(r("lead"), self.OVER)

    def test_send_start_stop_write_orders(self):
        self.env["KB_SESSION_ID"] = self.LEAD
        s = self.cli("crew", "send", "overseer", "Part", "one", "done")
        self.assertEqual(s.returncode, 0, s.stderr)
        self.assertIn("queued: send → Overview", s.stdout)
        st = self.cli("crew", "start", "--under", "me", "--title", "UI part", "--model", "sonnet",
                      "--about", "app-a/followups/x", "Build the screen")
        self.assertEqual(st.returncode, 0, st.stderr)
        self.cli("crew", "stop", "Auth tests")
        o = self.orders()
        self.assertEqual([x["kind"] for x in o], ["send", "start", "stop"])
        self.assertEqual((o[0]["to"], o[0]["text"], o[0]["from"]), (self.OVER, "Part one done", self.LEAD))
        self.assertEqual((o[1]["parent"], o[1]["title"], o[1]["model"], o[1]["lead"], o[1]["text"]),
                         (self.LEAD, "UI part", "sonnet", False, "Build the screen"))
        self.assertEqual(o[1]["about"], "app-a/followups/x")
        self.assertEqual(o[2]["to"], self.MEMBER)
        self.assertFalse(list((self.crew / "orders").glob(".*")))
        self.assertNotEqual(self.cli("crew", "start", "--lead", "--under", "me", "--title", "x").returncode, 0)

    def test_archive_me_writes_an_order(self):
        self.env["KB_SESSION_ID"] = self.SOLO
        r = self.cli("crew", "archive", "me")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("queued: archive → Auth docs", r.stdout)
        o = self.orders()[0]
        self.assertEqual((o["kind"], o["to"], o["from"]), ("archive", self.SOLO, self.SOLO))

    def test_factory_ask_and_log_write_orders(self):
        self.env["KB_SESSION_ID"] = self.LEAD
        r = self.cli("crew", "status")
        self.assertEqual(r.returncode, 0, r.stderr)
        a = self.cli("factory", "ask", "Which API version?", "--option", "v2 (Recommended)", "--option", "v1",
                     "--checkpoint", "missingKnowledge")
        self.assertEqual(a.returncode, 0, a.stderr)
        self.assertIn("doesn't depend on the answer", a.stdout)
        self.assertEqual(self.cli("factory", "log", "plan", "ready").returncode, 0)
        ask, log = self.orders()
        self.assertEqual((ask["kind"], ask["from"], ask["text"], ask["options"], ask["checkpoint"]),
                         ("factory_ask", self.LEAD, "Which API version?", ["v2 (Recommended)", "v1"], "missingKnowledge"))
        self.assertEqual((log["kind"], log["text"]), ("factory_log", "plan ready"))
        self.env.pop("KB_SESSION_ID")
        self.assertNotEqual(self.cli("factory", "log", "x").returncode, 0)

    def test_test_suggest_queues_a_suggestion_for_the_app(self):
        self.env["KB_SESSION_ID"] = self.LEAD
        r = self.cli("test", "suggest", "--scope", "app-a", "--text", "Serve with --host so the phone reaches it",
                     "--target", "w1", "--set", "start=npm run dev -- --host", "--set", "port=5173")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("accept or dismiss", r.stdout)
        o = self.orders()[0]
        self.assertEqual((o["kind"], o["scope"], o["target"], o["from"]), ("test_suggest", "app-a", "w1", self.LEAD))
        self.assertEqual(o["set"], {"start": "npm run dev -- --host", "port": "5173"})
        self.assertNotEqual(self.cli("test", "suggest", "--scope", "app-a", "--text", "x", "--set", "novalue").returncode, 0)
        self.env.pop("KB_SCOPE", None)
        self.assertNotEqual(self.cli("test", "suggest", "--text", "no scope").returncode, 0)

    def test_factory_status_reads_the_apps_file(self):
        self.assertIn("No software factory", self.cli("factory", "status").stdout)
        (self.crew / "factory.json").write_text(json.dumps({"factories": [{"name": "Android", "run": {
            "status": "running", "tasks": [{"workItem": 5, "title": "Fix it", "finished": None}],
            "questions": [{"workItem": 5, "text": "Which?", "answer": None}]}}]}))
        out = self.cli("factory", "status").stdout
        self.assertIn("Android: running", out)
        self.assertIn("#5 Fix it [working]", out)
        self.assertIn("? #5 Which?", out)

    def test_send_reads_stdin(self):
        r = self.cli("crew", "send", "aaaa", "-", stdin="from stdin\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.orders()[0]["text"], "from stdin")
        self.assertEqual(self.orders()[0]["from"], "cli")

    def test_status_tree_and_staleness(self):
        self.env["KB_SESSION_ID"] = self.MEMBER
        out = self.cli("crew", "status").stdout
        self.assertIn("Overview: Overview [cccc3333]", out)
        self.assertIn("★ Auth feature [aaaa1111] · app-a · working · Editing Login.kt · auto-crew", out)
        self.assertIn("    ● Auth tests [bbbb2222] · idle · haiku (you)", out)
        self.assertIn("Other sessions\n  ○ Auth docs", out)
        self.assertNotIn("doesn't seem", out)
        self.state["updated"] = "2020-01-01T00:00:00Z"
        (self.crew / "state.json").write_text(json.dumps(self.state))
        self.assertIn("doesn't seem", self.cli("crew", "status").stdout)
        self.assertIn("doesn't seem", self.cli("crew", "send", "aaaa", "hi").stderr)
        self.assertEqual(json.loads(self.cli("crew", "status", "--json").stdout)["updated"], "2020-01-01T00:00:00Z")


class StrategyTest(KbTestCase):
    def test_builtins_override_new_delete(self):
        rows = {l.split("\t")[0]: l.split("\t") for l in self.cli("strategy", "list").stdout.splitlines()}
        self.assertEqual(rows["auto-crew"][2:4], ["auto", "built-in"])
        self.assertIn("plan-first", rows)
        self.assertIn("kb crew start --under me", self.cli("strategy", "show", "auto-crew").stdout)
        r = self.cli("strategy", "new", "--title", "Auto crew", "--summary", "Mine", "--spawn", "auto",
                     "--max-sessions", "2", "--body-stdin", stdin="Do it my way.")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split()[0], "auto-crew")
        rows = {l.split("\t")[0]: l.split("\t") for l in self.cli("strategy", "list").stdout.splitlines()}
        self.assertEqual(rows["auto-crew"][3:], ["override", "Mine"])
        self.assertIn("Do it my way", self.cli("strategy", "show", "auto-crew").stdout)
        self.assertNotEqual(self.cli("strategy", "new", "--title", "Auto crew", "--body", "x").returncode, 0)
        self.assertIn("built-in one is back", self.cli("strategy", "delete", "auto-crew").stdout)
        self.assertNotEqual(self.cli("strategy", "delete", "plan-first").returncode, 0)
        self.cli("strategy", "new", "--title", "Pair", "--body", "Work with me.")
        rows = {l.split("\t")[0]: l.split("\t") for l in self.cli("strategy", "list").stdout.splitlines()}
        self.assertEqual(rows["pair"][2:4], ["none", "custom"])


class PullRequestCleanupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        def git(*args, cwd=self.repo):
            subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True,
                           env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"})
        self.git = git
        git("init", "-q", "-b", "main")
        (self.repo / "a.txt").write_text("a")
        git("add", "a.txt")
        git("commit", "-qm", "a")
        git("branch", "feature/1-x")
        self.wt = self.tmp / "wt"
        git("worktree", "add", "-q", str(self.wt), "feature/1-x")
        (self.wt / "b.txt").write_text("b")
        git("add", "b.txt", cwd=self.wt)
        git("commit", "-qm", "b", cwd=self.wt)
        self.tip = subprocess.run(["git", "-C", str(self.wt), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_finds_the_worktree_and_branch_a_pr_left(self):
        left = kb.pr_leftovers(self.repo, "feature/1-x", self.tip)
        self.assertEqual([Path(w["path"]).resolve() for w in left["worktrees"]], [self.wt.resolve()])
        self.assertTrue(left["local_branch"])
        self.assertTrue(left["local_branch_safe"])
        self.assertTrue(kb.has_leftovers(left))

    def test_cleanup_removes_both(self):
        done, refused = kb.cleanup_local(kb.pr_leftovers(self.repo, "feature/1-x", self.tip), True, True, False)
        self.assertEqual(refused, [])
        self.assertEqual(len(done), 2)
        self.assertFalse(self.wt.exists())
        self.assertFalse(kb.has_leftovers(kb.pr_leftovers(self.repo, "feature/1-x", self.tip)))

    def test_uncommitted_work_and_untaken_commits_are_kept(self):
        (self.wt / "c.txt").write_text("unsaved")
        (self.wt / "b.txt").write_text("changed")
        left = kb.pr_leftovers(self.repo, "feature/1-x", "0" * 40)
        self.assertTrue(left["worktrees"][0]["dirty"])
        self.assertFalse(left["local_branch_safe"])
        done, refused = kb.cleanup_local(left, True, True, False)
        self.assertEqual(done, [])
        self.assertEqual(len(refused), 2)
        self.assertTrue(self.wt.exists())

    def test_a_branch_checked_out_in_the_main_checkout_is_not_deleted(self):
        self.git("worktree", "remove", "--force", str(self.wt))
        self.git("checkout", "-q", "feature/1-x")
        left = kb.pr_leftovers(self.repo, "feature/1-x", self.tip)
        self.assertTrue(left["checked_out_in_main"])
        done, refused = kb.cleanup_local(left, True, True, False)
        self.assertIn("checked out", refused[0])

    def test_cleaning_up_anyway_switches_the_main_checkout_and_keeps_its_changes(self):
        self.git("worktree", "remove", "--force", str(self.wt))
        self.git("checkout", "-q", "feature/1-x")
        (self.repo / "notes.txt").write_text("mine")
        left = kb.pr_leftovers(self.repo, "feature/1-x", "0" * 40)
        self.assertTrue(left["main_dirty"])
        done, refused = kb.cleanup_local(left, True, True, True, target="main")
        self.assertEqual(refused, [])
        self.assertEqual(done[0], f"switched {self.repo} to main")
        self.assertIn("deleted branch feature/1-x", done)
        self.assertEqual((self.repo / "notes.txt").read_text(), "mine")
        branch = subprocess.run(["git", "-C", str(self.repo), "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(branch, "main")


class PullRequestVoteTest(KbTestCase):
    def test_vote_is_cast_as_the_signed_in_user(self):
        import argparse, io, contextlib
        sent = []

        def fake(method, url, pat, body=None, content_type=None):
            if "connectionData" in url:
                return {"authenticatedUser": {"id": "me-1"}}
            sent.append((method, url, body))
            return {}
        pr = {"repository": {"id": "repo-1"}}
        orig = (kb.ado_request, kb.ado_pat, kb.find_pr)
        kb.ado_request, kb.ado_pat = fake, (lambda: "pat")
        kb.find_pr = lambda root, i, pat: ("O", "P", [], "https://dev.azure.com/O/P/_apis", pr)
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                kb.cmd_pr(argparse.Namespace(action="vote", id=9, vote="approve-with-suggestions"))
        finally:
            kb.ado_request, kb.ado_pat, kb.find_pr = orig
        self.assertEqual(sent, [("PUT", "https://dev.azure.com/O/P/_apis/git/repositories/repo-1/pullRequests/9/reviewers/me-1?api-version=7.1", {"vote": 5})])
        self.assertEqual(out.getvalue(), "!9: voted approved with suggestions\n")


class PullRequestTest(unittest.TestCase):
    def test_threads_drop_system_and_deleted(self):
        raw = [
            {"id": 1, "comments": [{"id": 1, "commentType": "system", "content": "Policy status has been updated"}]},
            {"id": 2, "status": "active", "comments": [{"id": 1, "commentType": "text", "content": "Rename this",
                                                         "author": {"displayName": "Ana"}}],
             "threadContext": {"filePath": "/a/B.kt", "rightFileStart": {"line": 12}}},
            {"id": 3, "isDeleted": True, "comments": [{"id": 1, "commentType": "text", "content": "x"}]},
            {"id": 4, "status": "fixed", "properties": {"CodeReviewThreadType": {"$value": "VoteUpdate"}},
             "comments": [{"id": 1, "commentType": "text", "content": "voted"}]},
            {"id": 5, "status": "fixed", "comments": [{"id": 1, "commentType": "text", "content": "General",
                                                        "author": {"displayName": "Bo"}},
                                                       {"id": 2, "isDeleted": True, "content": "gone"}]},
        ]
        got = kb.pr_threads(raw)
        self.assertEqual([t["id"] for t in got], [2, 5])
        self.assertEqual((got[0]["file"], got[0]["line"], got[0]["comments"][0]["author"]), ("/a/B.kt", 12, "Ana"))
        self.assertEqual(len(got[1]["comments"]), 1)

    def evaluation(self, kind, status, blocking=True, **settings):
        return {"status": status, "configuration": {"isBlocking": blocking, "type": {"displayName": kind}, "settings": settings}}

    def test_merge_strategy_policy_sets_the_choices_and_is_not_a_blocker(self):
        ev = [self.evaluation("Require a merge strategy", "rejected", allowSquash=True),
              self.evaluation("Build", "approved", displayName="Build & Test")]
        self.assertEqual(kb.pr_allowed_strategies(ev), ["squash"])
        policies = kb.pr_policies(ev)
        self.assertEqual([p["name"] for p in policies], ["Build & Test"])
        self.assertEqual(kb.pr_blockers({"mergeStatus": "succeeded"}, policies, 0), [])

    def test_no_policy_allows_every_strategy(self):
        self.assertEqual(kb.pr_allowed_strategies([]), ["squash", "noFastForward", "rebase", "rebaseMerge"])

    def test_blockers_in_words(self):
        ev = [self.evaluation("Comment requirements", "rejected"),
              self.evaluation("Minimum number of reviewers", "queued"),
              self.evaluation("Required reviewers", "queued"),
              self.evaluation("Required reviewers", "queued", blocking=False),
              self.evaluation("Build", "rejected")]
        got = kb.pr_blockers({"mergeStatus": "conflicts", "isDraft": True}, kb.pr_policies(ev), 2)
        self.assertEqual(got, ["It is a draft", "It has merge conflicts", "2 open comments", "Waiting for approval",
                               "The build failed"])

    def test_expired_build_is_its_own_blocker(self):
        expired = {**self.evaluation("Build", "queued"), "context": {"isExpired": True, "buildId": 9}}
        self.assertEqual(kb.pr_blockers({"mergeStatus": "succeeded"}, kb.pr_policies([expired]), 0), ["The build expired"])
        queued = {**self.evaluation("Build", "queued"), "context": {"isExpired": False}}
        self.assertEqual(kb.pr_blockers({"mergeStatus": "succeeded"}, kb.pr_policies([queued]), 0), ["The build is queued"])

    def test_task_order_puts_work_in_progress_first_and_done_last(self):
        tasks = [{"id": 3, "state": "Done"}, {"id": 2, "state": "New"}, {"id": 1, "state": "In Progress"}, {"id": 0, "state": "Done"}]
        self.assertEqual([t["id"] for t in sorted(tasks, key=kb.task_order)], [1, 2, 0, 3])
        self.assertTrue(kb.task_is_done("Closed"))


class DiscussionTest(KbTestCase):
    def new(self):
        r = self.cli("new", "discussion", "--title", "Offline upload retries", "--body", "Should failed uploads retry forever?",
                     "--field", "channel=email", "--field", "thread=AAQk123", "--field", "people=[Ana, Bo]",
                     "--field", "waiting_on=others")
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.splitlines()[0]

    def test_new_discussion_has_the_sections_and_is_open(self):
        did = self.new()
        self.assertTrue(did.startswith("app-a/discussions/"))
        e = kb.find_entry(self.root, did)
        self.assertEqual(e.status, "open")
        for h in ("## Summary", "## Points raised", "## Open questions", "## Findings", "## Outcome"):
            self.assertIn(h, e.body)
        rows = json.loads(self.cli("discussion", "list", "--json").stdout)
        self.assertEqual([(r["id"], r["thread"], r["waiting_on"]) for r in rows], [(did, "AAQk123", "others")])

    def test_notes_land_in_their_sections_in_order(self):
        did = self.new()
        self.cli("discussion", "note", did, "--who", "Ana", "--date", "2026-11-10", "--text", "Retry 3 times, then give up")
        self.cli("discussion", "note", did, "--who", "Bo", "--date", "2026-11-11", "--waiting-on", "me", stdin="Retry until it works\nlike iOS")
        self.cli("discussion", "note", did, "--kind", "question", "--text", "What does the BFF do with duplicates?")
        self.cli("discussion", "note", did, "--kind", "finding", "--text", "The BFF dedups by note id")
        e = kb.find_entry(self.root, did)
        body = e.body
        points = body.split("## Points raised")[1].split("## Open questions")[0]
        self.assertEqual([l for l in points.splitlines() if l.strip()],
                         ["- 2026-11-10 · Ana: Retry 3 times, then give up", "- 2026-11-11 · Bo: Retry until it works like iOS"])
        self.assertIn("- [ ] What does the BFF do with duplicates?", body.split("## Open questions")[1].split("## Findings")[0])
        self.assertIn("- The BFF dedups by note id", body.split("## Findings")[1].split("## Outcome")[0])
        self.assertEqual(e.get("waiting_on"), "me")
        self.assertTrue(e.get("updated"))

    def test_conclude_writes_the_outcome_and_hides_it_from_the_open_list(self):
        did = self.new()
        r = self.cli("discussion", "status", did, "concluded", "--outcome", "Retry 3 times with backoff.")
        self.assertEqual(r.returncode, 0, r.stderr)
        e = kb.find_entry(self.root, did)
        self.assertEqual(e.status, "concluded")
        self.assertTrue(e.body.rstrip().endswith("## Outcome\nRetry 3 times with backoff."))
        self.assertEqual(json.loads(self.cli("discussion", "list", "--json").stdout), [])
        self.assertEqual(len(json.loads(self.cli("discussion", "list", "--all", "--json").stdout)), 1)

    def test_open_discussions_are_in_the_session_context(self):
        did = self.new()
        ctx = self.cli("context").stdout
        self.assertIn("### Open discussions (1)", ctx)
        self.assertIn(did, ctx)

    def test_append_creates_a_missing_section_before_the_outcome(self):
        body = "## Summary\nx\n\n## Outcome\n"
        got = kb.discussion_section_append(body, "Findings", "- one")
        self.assertEqual(got, "## Summary\nx\n\n## Findings\n- one\n\n## Outcome\n")


class ReferenceTest(KbTestCase):
    def test_reference_is_saved_listed_and_named_in_the_context(self):
        r = self.cli("new", "reference", "--title", "Upload contract from the BFF team", "--summary", "What the BFF dedups on",
                     "--field", "kind=email", "--field", "url=https://outlook.office.com/mail/x", "--field", "captured=2026-11-12",
                     "--body-stdin", stdin="## Why it matters\nDedup rules\n\n## Content\n**Ana B**, 2026-11-10:\nWe dedup by note id.\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = r.stdout.splitlines()[0]
        self.assertTrue(rid.startswith("app-a/references/"))
        e = kb.find_entry(self.root, rid)
        self.assertEqual(e.get("kind"), "email")
        self.assertIn("We dedup by note id.", e.body)
        ctx = self.cli("context").stdout
        self.assertIn("### Saved references (1)", ctx)
        self.assertIn(f"`{rid}` email: **Upload contract from the BFF team**", ctx)
        self.assertIn(rid, self.cli("search", "dedup").stdout)

    def test_template_has_why_and_content(self):
        r = self.cli("new", "reference", "--title", "Note", "--body", "Because")
        e = kb.find_entry(self.root, r.stdout.splitlines()[0])
        self.assertEqual(e.body, "## Why it matters\nBecause\n\n## Content\n")


if __name__ == "__main__":
    unittest.main()


class ClosedPRTest(unittest.TestCase):
    def test_recently_closed_prs_are_kept_and_old_or_open_ones_are_not(self):
        import datetime as dt
        now = dt.datetime(2026, 11, 17, 12, tzinfo=dt.timezone.utc)
        pr = {"pullRequestId": 7, "title": "Fix", "status": "completed", "closedDate": "2026-11-17T09:00:00.123Z",
              "repository": {"name": "app"}}
        brief = kb.closed_pr_brief(pr, now)
        self.assertEqual(brief["id"], 7)
        self.assertEqual(brief["status"], "completed")
        self.assertEqual(brief["repo"], "app")
        self.assertIsNone(kb.closed_pr_brief({**pr, "closedDate": "2026-11-01T09:00:00Z"}, now))
        self.assertIsNone(kb.closed_pr_brief({**pr, "status": "active"}, now))
        self.assertIsNone(kb.closed_pr_brief({**pr, "closedDate": ""}, now))


class HtmlToTextTest(unittest.TestCase):
    def test_rich_text_becomes_plain_lines(self):
        html = "<div>Hello&nbsp;there</div><ul><li>one</li><li>two &amp; three</li></ul><p>End<br>line</p>"
        self.assertEqual(kb.html_to_text(html), "Hello there\n\n- one\n- two & three\nEnd\nline")
        self.assertEqual(kb.html_to_text(""), "")


class ShareTest(unittest.TestCase):
    """Every entry lives in the private folder; shared ones also in the repository, kept in sync."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "kb"
        self.remote = self.tmp / "remote.git"
        self.repo = self.tmp / "repos" / "app"
        self.ref = self.tmp / "repos" / "lib"
        (self.root / "shared").mkdir(parents=True)
        (self.root / "shared" / "kb.json").write_text(json.dumps({"version": 2, "projects": [
            {"id": "p", "title": "P", "scopes": [
                {"id": "all", "title": "Overview", "paths": [], "wide": True},
                {"id": "app", "title": "App", "paths": [str(self.repo)]},
                {"id": "web", "title": "Web", "paths": [], "includes": ["app"], "related": ["lib"]},
                {"id": "lib", "title": "Lib", "paths": [str(self.ref)]},
            ]}]}))
        for sid in ("all", "app", "web", "lib"):
            (self.root / sid).mkdir()
        g = lambda *a, cwd=None: subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *a],
                                               cwd=cwd, capture_output=True, text=True, check=True)
        self.git = g
        g("init", "-q", "--bare", "-b", "main", str(self.remote))
        g("clone", "-q", str(self.remote), str(self.repo))
        g("commit", "-q", "--allow-empty", "-m", "init", cwd=self.repo)
        g("push", "-q", "-u", "origin", "main", cwd=self.repo)
        self.ref.mkdir(parents=True)
        self.env = {**os.environ, "KB_ROOT": str(self.root), "CLAUDE_PLUGIN_DATA": str(self.tmp / "data")}
        self.env.pop("KB_SCOPE", None)
        os.environ.update({"KB_ROOT": str(self.root), "CLAUDE_PLUGIN_DATA": str(self.tmp / "data")})

    def cli(self, *args, cwd=None, env=None):
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), *args], cwd=cwd or self.repo,
                           env={**self.env, **(env or {})}, capture_output=True, text=True)
        return r

    def status(self):
        return json.loads(self.cli("share", "status", "--scope", "app", "--json").stdout)["scopes"]["app"]

    def test_new_decision_is_in_both_and_meeting_stays_private(self):
        eid = self.cli("new", "decision", "--title", "Use Room", "--body", "Because.").stdout.split()[0]
        private = list((self.root / "app" / "decisions").glob("*use-room.md"))
        team = list((self.repo / "knowledgebase" / "decisions").glob("*use-room.md"))
        self.assertTrue(private and team)
        self.assertEqual(private[0].read_text(), team[0].read_text())
        self.assertEqual(self.status()["entries"][eid], "uncommitted")
        disc = self.cli("new", "discussion", "--title", "Login").stdout.split()[0]
        self.assertNotIn(disc, self.status()["entries"])
        self.assertFalse((self.repo / "knowledgebase" / "discussions").exists())

    def test_states_follow_commit_and_push(self):
        eid = self.cli("new", "fact", "--title", "Min SDK 26").stdout.split()[0]
        self.git("add", "-A", cwd=self.repo)
        self.git("commit", "-q", "-m", "kb", cwd=self.repo)
        self.assertEqual(self.status()["entries"][eid], "unpushed")
        self.git("push", "-q", cwd=self.repo)
        self.assertEqual(self.status()["entries"][eid], "pushed")

    def test_branch_without_the_entry_keeps_it_in_the_kb(self):
        eid = self.cli("new", "fact", "--title", "Min SDK 26").stdout.split()[0]
        self.git("add", "-A", cwd=self.repo)
        self.git("commit", "-q", "-m", "kb", cwd=self.repo)
        self.git("switch", "-q", "-c", "old", "HEAD~1", cwd=self.repo)
        self.assertEqual(self.cli("share", "sync").returncode, 0)
        self.assertTrue(list((self.root / "app" / "facts").glob("*min-sdk-26.md")), "still in the KB")
        self.assertFalse((self.repo / "knowledgebase" / "facts").exists(), "not put back into the old branch")
        self.assertEqual(self.status()["entries"][eid], "missing")
        self.assertIn("Min SDK 26", self.cli("show", eid).stdout)

    def test_teammate_entry_is_copied_in_and_their_edit_flows_back(self):
        team = self.repo / "knowledgebase" / "facts"
        team.mkdir(parents=True)
        (team / "api.md").write_text("---\ntitle: API v2\n---\nOld.\n")
        self.cli("share", "sync")
        mine = self.root / "app" / "facts" / "api.md"
        self.assertIn("Old.", mine.read_text())
        (team / "api.md").write_text("---\ntitle: API v2\n---\nNew from a teammate.\n")
        self.cli("share", "sync")
        self.assertIn("New from a teammate.", mine.read_text())
        mine.write_text("---\ntitle: API v2\n---\nMy edit.\n")
        self.cli("share", "sync")
        self.assertIn("New from a teammate.", (team / "api.md").read_text(), "an edit goes out only when pushed")
        self.assertIn("My edit.", mine.read_text(), "and the KB keeps it")
        self.cli("share", "sync", "--push", "app/facts/api")
        self.assertIn("My edit.", (team / "api.md").read_text())

    def test_edit_in_a_worktree_stays_out_of_the_main_checkout(self):
        eid = self.cli("new", "fact", "--title", "Min SDK 26").stdout.split()[0]
        self.git("add", "-A", cwd=self.repo)
        self.git("commit", "-q", "-m", "kb", cwd=self.repo)
        self.cli("share", "sync")
        wt = self.tmp / "wt"
        self.git("worktree", "add", "-q", "-b", "feature", str(wt), cwd=self.repo)
        name = next((self.root / "app" / "facts").glob("*min-sdk-26.md")).name
        mine = self.root / "app" / "facts" / name
        mine.write_text(mine.read_text() + "\nNow 28.\n")
        r = self.cli("share", "sync", "--scope", "app", "--push", eid, cwd=wt)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Now 28.", (wt / "knowledgebase" / "facts" / name).read_text())
        self.cli("share", "sync")
        self.assertNotIn("Now 28.", (self.repo / "knowledgebase" / "facts" / name).read_text())
        self.assertIn("Now 28.", (self.root / "app" / "facts" / name).read_text(), "the KB has the newest")
        self.assertEqual(self.git("status", "--porcelain", cwd=self.repo).stdout.strip(), "")

    def test_branch_switch_keeps_the_kb_copy(self):
        eid = self.cli("new", "fact", "--title", "Min SDK 26", "--body", "Old.").stdout.split()[0]
        self.git("add", "-A", cwd=self.repo)
        self.git("commit", "-q", "-m", "kb", cwd=self.repo)
        self.cli("share", "sync")
        self.git("switch", "-q", "-c", "next", cwd=self.repo)
        mine = next((self.root / "app" / "facts").glob("*min-sdk-26.md"))
        mine.write_text(mine.read_text().replace("Old.", "New."))
        self.cli("share", "sync", "--push", eid)
        self.git("commit", "-q", "-am", "edit", cwd=self.repo)
        self.git("switch", "-q", "main", cwd=self.repo)
        self.cli("share", "sync")
        name = next((self.root / "app" / "facts").glob("*min-sdk-26.md")).name
        self.assertIn("New.", (self.root / "app" / "facts" / name).read_text())
        self.assertIn("Old.", (self.repo / "knowledgebase" / "facts" / name).read_text())

    def test_claude_editing_the_kb_copy_reaches_the_repository(self):
        eid = self.cli("new", "fact", "--title", "Hooked", "--body", "One.").stdout.split()[0]
        mine = next((self.root / "app" / "facts").glob("*hooked.md"))
        mine.write_text(mine.read_text().replace("One.", "Two."))
        payload = {"session_id": "s1", "tool_name": "Edit", "tool_input": {"file_path": str(mine)}}
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "hook", "post-tool"], cwd=self.repo,
                           env=self.env, input=json.dumps(payload), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Two.", (self.repo / "knowledgebase" / "facts" / mine.name).read_text())
        self.assertTrue(eid)

    def test_make_private_and_share_again_and_delete(self):
        eid = self.cli("new", "fact", "--title", "Secret").stdout.split()[0]
        team = self.repo / "knowledgebase" / "facts"
        self.assertEqual(self.cli("share", "set", eid, "private").returncode, 0)
        self.assertFalse(list(team.glob("*secret.md")))
        self.assertNotIn(eid, self.status()["entries"])
        self.cli("share", "sync")
        self.assertFalse(list(team.glob("*secret.md")), "sync doesn't share it again")
        self.cli("share", "set", eid, "shared")
        self.assertTrue(list(team.glob("*secret.md")))
        self.cli("delete", eid)
        self.assertFalse(list(team.glob("*secret.md")), "deleting removes the shared copy")
        self.assertFalse(list((self.root / "app" / "facts").glob("*secret.md")))

    def test_scope_without_repo_cannot_share(self):
        eid = self.cli("new", "fact", "--project", "all", "--cross-project", "--title", "Wide").stdout.split()[0]
        r = self.cli("share", "set", eid, "shared")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no repository", r.stderr)

    def test_repos_lists_work_and_reference_and_pulls(self):
        out = json.loads(self.cli("repos", "--scope", "web", "--json").stdout)["repos"]
        self.assertEqual([(r["scope"], r["role"]) for r in out], [("app", "work"), ("lib", "reference")])
        other = self.tmp / "other"
        self.git("clone", "-q", str(self.remote), str(other))
        self.git("commit", "-q", "--allow-empty", "-m", "theirs", cwd=other)
        self.git("push", "-q", cwd=other)
        st = json.loads(self.cli("repos", "--scope", "app", "--fetch", "--json").stdout)["repos"][0]
        self.assertEqual(st["behind"], 1)
        r = self.cli("repos", "pull", "--scope", "app")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("App: pulled", r.stdout)
        st = json.loads(self.cli("repos", "--scope", "app", "--json").stdout)["repos"][0]
        self.assertEqual(st["behind"], 0)
        lib = self.cli("repos", "pull", "--scope", "web", "--repo", "lib")
        self.assertIn("not a git repository", lib.stdout)

    def test_context_names_work_and_knowledge_only_repositories(self):
        r = subprocess.run([sys.executable, str(PLUGIN / "scripts" / "kb.py"), "hook", "session-start"], cwd=self.repo,
                           env={**self.env, "KB_SCOPE": "web"}, input="{}", capture_output=True, text=True)
        text = json.loads(r.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("Works on: App", text)
        self.assertIn("Knowledge only, read but never change: Lib", text)
