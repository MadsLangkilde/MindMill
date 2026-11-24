import Foundation
import KBCore

/// The projects editor's save (`projects.config.save`): kb.json, and the scopes it removes moved with `kb scope remove`.
extension MindmillEngine {
    /// Saves changed projects into kb.json, then deletes the scopes they removed through the CLI, which moves their
    /// entries. Returns each project's id and scope ids.
    @discardableResult
    public func saveProjects(_ drafts: [ProjectDraft]) async throws -> [(project: String, scopes: [String])] {
        var r = (try? Registry.load(registryURL)) ?? Registry()
        var made: [(project: String, scopes: [String])] = []
        var removals: [String: String] = [:]
        for d in drafts {
            let out = try d.apply(to: r)
            r = out.registry
            made.append((out.project, out.scopes))
            removals.merge(out.removals) { a, _ in a }
        }
        try r.save(root: rootURL)
        var failures: [String] = []
        for (id, to) in removals.sorted(by: { $0.key < $1.key }) {
            do { _ = try await cli.run(["scope", "remove", id, "--move-to", to]) } catch { failures.append(error.localizedDescription) }
        }
        reload()
        projectsChanged()
        if !failures.isEmpty { throw ActionError(failures.joined(separator: " ")) }
        return made
    }

    /// Tells phones and desktop shells that the projects changed.
    public func projectsChanged() {
        guard (remote.isRunning && !remote.connected.isEmpty) || !remote.desktops.isEmpty else { return }
        remote.broadcast("projects.changed")
        remote.broadcast("index.changed")
    }

    func registerProjectMethods() {
        methods.register("projects.config.save") { [unowned self] _, p in
            let r = (try? Registry.load(registryURL)) ?? Registry()
            let draft: ProjectDraft
            do {
                draft = try ProjectDraft.from(json: p["project"] ?? [:], id: p["id"]?.string, registry: r)
            } catch {
                throw RemoteError.badParams(error.localizedDescription)
            }
            if let problem = draft.problem(in: r) { throw RemoteError.badParams(problem) }
            do {
                let made = try await saveProjects([draft])
                guard let first = made.first else { throw RemoteError.badParams("Nothing was saved.") }
                return ["id": .string(first.project), "scopes": .array(first.scopes.map(JSONValue.string))]
            } catch let e as RemoteError {
                throw e
            } catch {
                throw RemoteError.badParams(error.localizedDescription)
            }
        }
    }
}
