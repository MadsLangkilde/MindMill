import Foundation
import KBCore
import KBEngine

extension AppModel {
    /// Binary frames the engine leaves to the app: a phone's screenshots for the meeting running on the Mac.
    func remoteBinary(_ frame: RemoteFrame, from client: RemoteClient) {
        guard frame.kind == "screen" else { return }
        remoteMeetingScreen(frame, from: client)
    }

    func remoteMeetingScreen(_ frame: RemoteFrame, from client: RemoteClient) {
        guard let raw = frame.header["meeting"]?.string, let id = EntryID(raw), let c = meetingControllers[id] else { return }
        c.showRemotePicture(frame.payload)
    }
}
