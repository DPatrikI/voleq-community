// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine

@MainActor
final class WorkspaceLifecycleForwarder {
    private let notificationCenter: NotificationCenter
    private let prepareAudioForSleep: @MainActor () -> Void
    private let resumeAudioAfterWake: @MainActor () -> Void
    private let updateApplicationActivatedOrWoke: @MainActor () -> Void
    private var sleepSubscription: AnyCancellable?
    private var audioWakeSubscription: AnyCancellable?
    private var updateWakeSubscription: AnyCancellable?

    init(
        notificationCenter: NotificationCenter,
        prepareAudioForSleep: @escaping @MainActor () -> Void,
        resumeAudioAfterWake: @escaping @MainActor () -> Void,
        updateApplicationActivatedOrWoke: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.prepareAudioForSleep = prepareAudioForSleep
        self.resumeAudioAfterWake = resumeAudioAfterWake
        self.updateApplicationActivatedOrWoke = updateApplicationActivatedOrWoke
    }

    func start() {
        guard sleepSubscription == nil,
              audioWakeSubscription == nil,
              updateWakeSubscription == nil
        else { return }

        sleepSubscription = notificationCenter.publisher(
            for: NSWorkspace.willSleepNotification
        )
        .sink { [weak self] _ in
            self?.prepareAudioForSleep()
        }

        // Audio reconstruction and update scheduling intentionally receive
        // wake independently. Neither lifecycle can suppress the other.
        audioWakeSubscription = notificationCenter.publisher(
            for: NSWorkspace.didWakeNotification
        )
        .sink { [weak self] _ in
            self?.resumeAudioAfterWake()
        }

        updateWakeSubscription = notificationCenter.publisher(
            for: NSWorkspace.didWakeNotification
        )
        .sink { [weak self] _ in
            self?.updateApplicationActivatedOrWoke()
        }
    }

    func applicationActivated() {
        resumeAudioAfterWake()
        updateApplicationActivatedOrWoke()
    }
}
