// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Combine
import VolEqMacAudio

@MainActor
protocol VolEqControlSurfaceModel: ObservableObject {
    var processes: [AudioProcess] { get }
    var selectedProcessID: AudioObjectID? { get set }
    var mode: CaptureMode { get set }
    var speechAwarenessEnabled: Bool { get set }
    var captureState: AudioCaptureStateSnapshot { get }

    func refreshProcesses()
    func toggle()
}

@available(macOS 14.2, *)
extension AudioCaptureController: VolEqControlSurfaceModel { }

extension VolEqControlSurfaceModel {
    var capturePresentation: CapturePresentation {
        CapturePresentation(
            state: captureState,
            mode: mode,
            selectedProcessID: selectedProcessID,
            processes: processes
        )
    }
}
