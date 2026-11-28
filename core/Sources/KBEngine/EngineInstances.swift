import Foundation
import KBCore

/// Instances in the engine (docs/remote-api.md, Instances): the list, a new one, a new project in one, and switching,
/// which the host does.
extension MindmillEngine {
    /// The config's instances, with this engine's open one as current even when it started on `--root`.
    public func instanceList() -> InstanceList {
        var list = InstanceList.load(configURL: configURL)
        if let instance, list.instance(instance.id) != nil { list.current = instance.id }
        return list
    }

    public func instancesJSON() -> JSONValue {
        let list = instanceList()
        return ["current": .string(list.current), "instances": .array(list.instances.map { i in
            let registry = KBLayout.home(root: i.rootURL).appendingPathComponent("kb.json")
            let projects = (try? Registry.load(registry))?.projects.count ?? 0
            return ["id": .string(i.id), "name": .string(i.name), "path": .string(KBConfig.abbreviateTilde(i.rootURL.path)),
                    "exists": .bool(FileManager.default.fileExists(atPath: registry.path)), "projects": .number(Double(projects))]
        })]
    }

    /// Adds an instance for `folder`, making its knowledge base unless it has one.
    @discardableResult
    public func createInstance(name: String, folder: URL) throws -> MindmillInstance {
        var list = instanceList()
        let made = try list.add(name: name, root: folder.path)
        try InstanceFolder.prepare(folder)
        try list.save(configURL: configURL)
        return made
    }

    /// A new project in another instance's knowledge base; the open one's projects don't change.
    public func addProject(_ draft: ProjectDraft, to target: MindmillInstance) throws -> (project: String, scopes: [String]) {
        let url = KBLayout.home(root: target.rootURL).appendingPathComponent("kb.json")
        let r = (try? Registry.load(url)) ?? Registry()
        if let problem = draft.problem(in: r) { throw InstanceError(problem) }
        let out = try draft.apply(to: r)
        try out.registry.save(root: target.rootURL)
        return (out.project, out.scopes)
    }

    func registerInstanceMethods() {
        methods.register("instances.list") { [unowned self] _, _ in instancesJSON() }

        methods.register("instance.create") { [unowned self] _, p in
            guard let name = p["name"]?.string, let path = p["path"]?.string, !path.isEmpty else {
                throw RemoteError.badParams("Give the instance a name and a folder.")
            }
            let made: MindmillInstance
            do {
                made = try createInstance(name: name, folder: URL(fileURLWithPath: try FolderListing.underHome(path).full))
            } catch {
                throw RemoteError.badParams(error.localizedDescription)
            }
            let switching = p["open"]?.bool == true ? try switchInstance(made.id) : false
            return ["id": .string(made.id), "switching": .bool(switching)]
        }

        methods.register("instance.switch") { [unowned self] _, p in
            guard let id = p["id"]?.string, !id.isEmpty else { throw RemoteError.badParams("Which instance?") }
            return ["switching": .bool(try switchInstance(id))]
        }

        methods.register("folders.create") { _, p in
            do {
                return ["folder": try FolderListing.create(in: p["parent"]?.string ?? "~", name: p["name"]?.string ?? "")]
            } catch {
                throw RemoteError.badParams(error.localizedDescription)
            }
        }
    }

    /// Asks the host to open the instance, a moment after this answer has gone out. False: it is open already.
    func switchInstance(_ id: String) throws -> Bool {
        let list = instanceList()
        guard let target = list.instance(id) else { throw RemoteError.notFound("There's no such instance on this \(platform.machineWord).") }
        guard id != list.current else { return false }
        guard let host = onSwitchInstance else {
            throw RemoteError.unavailable("This \(platform.machineWord) can't switch instances from the phone yet.")
        }
        guard FileManager.default.fileExists(atPath: KBLayout.home(root: target.rootURL).appendingPathComponent("kb.json").path) else {
            throw RemoteError.badParams("\(target.name)'s folder (\(target.root)) isn't there any more.")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            host(target)
        }
        return true
    }
}
