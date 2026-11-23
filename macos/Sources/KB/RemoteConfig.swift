import Foundation
import KBCore

/// The phone's factory editor and its assistant: methods whose data is too rich for an action's flat parameters.
extension AppModel {
    func remoteConfig(_ method: String, _ p: JSONValue) async throws -> JSONValue? {
        switch method {
        case "factory.config.get":
            loadFactoriesIfNeeded()
            if strategies.isEmpty { reloadStrategies() }
            let f = try p["id"]?.string.map { id -> Factory in
                guard let f = factory(id) else { throw RemoteError.notFound("No such factory") }
                return f
            }
            let rules = f?.rules ?? newFactoryRules()
            let name = f?.name ?? (factories.isEmpty ? "Software Factory" : "Software Factory \(factories.count + 1)")
            let options = FactoryConfig.options(scopes: factoryScopes.map { .init(id: $0.id, title: $0.title) },
                                                strategies: strategies.map { ($0.slug, $0.title) })
            let factoryJSON: JSONValue = f.map { f in
                let status = f.run == nil ? "never" : f.run!.isPaused ? "paused" : f.run!.status.rawValue
                return ["id": .string(f.id), "name": .string(f.name), "status": .string(status), "running": .bool(f.isRunning)]
            } ?? .null
            return ["factory": factoryJSON, "name": .string(name), "rules": FactoryConfig.json(rules),
                    "problems": .array(rules.problems.map(JSONValue.string)), "options": options]

        case "factory.config.save":
            loadFactoriesIfNeeded()
            let existing = try p["id"]?.string.flatMap { $0.isEmpty ? nil : $0 }.map { id -> Factory in
                guard let f = factory(id) else { throw RemoteError.notFound("No such factory") }
                return f
            }
            let rules: FactoryRules
            do {
                rules = try FactoryConfig.merge(existing?.rules ?? newFactoryRules(), with: p["rules"] ?? [:])
            } catch {
                throw RemoteError.badParams(error.localizedDescription)
            }
            let problems = rules.problems
            guard problems.isEmpty else { throw RemoteError.badParams(problems.joined(separator: " ")) }
            let id = saveFactory(id: existing?.id, name: p["name"]?.string ?? existing?.name ?? "", rules: rules)
            return ["id": .string(id)]

        case "factory.config.delete":
            loadFactoriesIfNeeded()
            guard let id = p["id"]?.string, let f = factory(id) else { throw RemoteError.notFound("No such factory") }
            if f.run?.status == .running { stopFactory(f.id) }
            deleteFactory(f.id)
            return ["deleted": true]

        case "assistant.open":
            let (s, created) = await assistantSession(scope: p["scope"]?.string, new: p["new"]?.bool ?? false, show: false)
            return ["session": remoteSession(s), "created": .bool(created)]

        default:
            return nil
        }
    }
}
