// SPDX-License-Identifier: MPL-2.0

import VolEqCore

enum CaptureLifecycleEvent: Equatable, Sendable {
    case settingsChanged(LevelingSettings)
    case start(CaptureIntent)
    case retry(CaptureIntent)
    case stop
    case sleep(CaptureIntent?)
    case wake
    case routeChanged
    case callbacksStalled
    case terminationRequested
    case startFlowBegan(CaptureIntent)
    case recoveryStartFlowBegan(
        previous: CaptureIntent,
        restored: CaptureIntent
    )
    case processRefreshSucceeded
    case processRefreshFailed(CaptureIntent?)
    case routeMonitoringStarted(CaptureIntent)
    case routeMonitoringFailed(CaptureIntent?)
    case explanationAccepted(CaptureIntent)
    case explanationDeclined(CaptureIntent)
    case startupFailed(CaptureLifecyclePhase)
    case pipelineStarted(CaptureIntent)
    case pipelineStartFailed(CaptureIntent)
    case teardownCompleted(CaptureTeardownCompletion)
    case teardownFailed
    case recoveryFailed(CaptureIntent, RecoveryFailure)
    case processingFailed(CaptureIntent?)
}

enum CaptureTeardownCompletion: Equatable, Sendable {
    case stopped
    case suspended(CaptureIntent)
    case recoveryReady(CaptureIntent, AudioRecoveryReason)
    case failed(CaptureLifecyclePhase)
}

enum CaptureLifecycleDirective: Equatable, Sendable {
    case ignore
    case beginStart(CaptureIntent)
    case beginRetry(CaptureIntent)
    case stop(CaptureIntent?)
    case sleep(CaptureIntent)
    case queueWake
    case cancelQueuedWake
    case recover(CaptureIntent, AudioRecoveryReason)
    case refreshReadyStatus
    case transition(CaptureLifecyclePhase)
}

struct CaptureLifecycleReducer {
    static func reduce(
        phase: CaptureLifecyclePhase,
        event: CaptureLifecycleEvent
    ) -> CaptureLifecycleDirective {
        switch event {
        case let .settingsChanged(settings):
            let updated = phase.updatingLevelingSettings(settings)
            return updated == phase ? .ignore : .transition(updated)

        case let .start(intent):
            switch phase {
            case .stopped, .explanationDeclined, .ready,
                 .processDiscoveryFailed, .routeMonitoringFailed, .failed,
                 .verifiedFailure:
                return .beginStart(intent)
            case .installingRouteMonitor, .explaining, .preparing,
                 .active, .stopping,
                 .suspending, .suspended, .recovering, .recoveryFailed,
                 .cleanupFailed:
                return .ignore
            }

        case let .retry(intent):
            guard case .recoveryFailed = phase else { return .ignore }
            return .beginRetry(intent)

        case .stop:
            switch phase {
            case .stopped, .explanationDeclined, .ready,
                 .processDiscoveryFailed,
                 .routeMonitoringFailed, .failed, .verifiedFailure,
                 .stopping:
                return .ignore
            case .installingRouteMonitor, .explaining, .preparing,
                 .active,
                 .suspending, .suspended, .recovering, .recoveryFailed,
                 .cleanupFailed:
                return .stop(phase.resumableIntent)
            }

        case let .sleep(fallbackIntent):
            switch phase {
            case .installingRouteMonitor, .explaining, .preparing,
                 .active, .recovering:
                guard let intent = phase.resumableIntent ?? fallbackIntent else {
                    return .ignore
                }
                return .sleep(intent)
            case .suspending:
                return .cancelQueuedWake
            case .stopped, .explanationDeclined, .ready, .stopping,
                 .suspended, .recoveryFailed,
                 .processDiscoveryFailed, .routeMonitoringFailed, .failed, .verifiedFailure,
                 .cleanupFailed:
                return .ignore
            }

        case .wake:
            switch phase {
            case .suspending:
                return .queueWake
            case let .suspended(intent):
                return .recover(intent, .systemWake)
            default:
                return .ignore
            }

        case .routeChanged:
            switch phase {
            case .active, .preparing:
                guard let intent = phase.resumableIntent else { return .ignore }
                return .recover(intent, .outputRouteChanged)
            case .ready:
                return .refreshReadyStatus
            default:
                return .ignore
            }

        case .callbacksStalled:
            guard case let .active(intent) = phase else { return .ignore }
            return .recover(intent, .stalledCallbacks)

        case .terminationRequested:
            switch phase {
            case .stopped, .explanationDeclined, .ready,
                 .processDiscoveryFailed,
                 .routeMonitoringFailed, .failed, .verifiedFailure,
                 .stopping:
                return .ignore
            case .installingRouteMonitor, .explaining, .preparing,
                 .active,
                 .suspending, .suspended, .recovering, .recoveryFailed,
                 .cleanupFailed:
                return .stop(phase.resumableIntent)
            }

        case let .startFlowBegan(intent):
            switch phase {
            case let .installingRouteMonitor(currentIntent)
                where currentIntent.matchesOperationIdentity(of: intent):
                return .transition(.explaining(
                    intent.replacingLevelingSettings(
                        currentIntent.levelingSettings
                    )
                ))
            case .stopped, .explanationDeclined, .ready,
                 .processDiscoveryFailed, .routeMonitoringFailed, .failed,
                 .verifiedFailure:
                return .transition(.explaining(intent))
            default:
                return .ignore
            }

        case let .recoveryStartFlowBegan(previous, restored):
            guard case let .recovering(currentIntent, _) = phase,
                  currentIntent.matchesOperationIdentity(of: previous)
            else { return .ignore }
            return .transition(.explaining(
                restored.replacingLevelingSettings(
                    currentIntent.levelingSettings
                )
            ))

        case .processRefreshSucceeded:
            switch phase {
            case .stopped, .ready, .processDiscoveryFailed:
                return .transition(.ready)
            default:
                return .ignore
            }

        case let .processRefreshFailed(intent):
            switch phase {
            case .stopped, .ready, .processDiscoveryFailed:
                return .transition(.processDiscoveryFailed(intent))
            default:
                return .ignore
            }

        case let .routeMonitoringStarted(intent):
            switch phase {
            case .stopped, .explanationDeclined, .ready,
                 .processDiscoveryFailed, .routeMonitoringFailed,
                 .failed, .verifiedFailure:
                return .transition(.installingRouteMonitor(intent))
            default:
                return .ignore
            }

        case let .routeMonitoringFailed(intent):
            switch phase {
            case .stopped, .explanationDeclined, .ready,
                 .installingRouteMonitor,
                 .processDiscoveryFailed, .routeMonitoringFailed,
                 .failed, .verifiedFailure:
                return .transition(.routeMonitoringFailed(intent))
            default:
                return .ignore
            }

        case let .explanationAccepted(intent):
            guard case let .explaining(currentIntent) = phase,
                  currentIntent.matchesOperationIdentity(of: intent)
            else { return .ignore }
            return .transition(.preparing(
                intent.replacingLevelingSettings(
                    currentIntent.levelingSettings
                )
            ))

        case let .explanationDeclined(intent):
            guard case let .explaining(currentIntent) = phase,
                  currentIntent.matchesOperationIdentity(of: intent)
            else { return .ignore }
            return .transition(.explanationDeclined)

        case let .startupFailed(failurePhase):
            switch phase {
            case .explaining, .preparing:
                guard failurePhase.isTerminalFailure else { return .ignore }
                let latestSettings = phase.resumableIntent?.levelingSettings
                return .transition(latestSettings.map {
                    failurePhase.updatingLevelingSettings($0)
                } ?? failurePhase)
            default:
                return .ignore
            }

        case let .pipelineStarted(intent):
            guard case let .preparing(currentIntent) = phase,
                  currentIntent.matchesOperationIdentity(of: intent)
            else { return .ignore }
            return .transition(.active(currentIntent))

        case let .pipelineStartFailed(intent):
            guard case let .preparing(currentIntent) = phase,
                  currentIntent.matchesOperationIdentity(of: intent)
            else { return .ignore }
            return .transition(.stopping(currentIntent))

        case let .teardownCompleted(completion):
            switch (phase, completion) {
            case (.stopping, .stopped):
                return .transition(.stopped)
            case let (.suspending(currentIntent), .suspended(intent))
                where currentIntent.matchesOperationIdentity(of: intent):
                return .transition(.suspended(currentIntent))
            case let (
                .recovering(currentIntent, currentReason),
                .recoveryReady(intent, reason)
            ) where currentIntent.matchesOperationIdentity(of: intent)
                && currentReason == reason:
                return .recover(currentIntent, reason)
            case let (.stopping(currentIntent), .failed(failurePhase))
                where failurePhase.isTerminalFailure:
                let latestSettings = currentIntent?.levelingSettings
                return .transition(latestSettings.map {
                    failurePhase.updatingLevelingSettings($0)
                } ?? failurePhase)
            default:
                return .ignore
            }

        case .teardownFailed:
            switch phase {
            case .stopping, .suspending, .recovering:
                return .transition(.cleanupFailed)
            default:
                return .ignore
            }

        case let .recoveryFailed(intent, failure):
            guard case let .recovering(currentIntent, _) = phase,
                  currentIntent.matchesOperationIdentity(of: intent)
            else { return .ignore }
            return .transition(.recoveryFailed(currentIntent, failure))

        case let .processingFailed(intent):
            guard case let .active(currentIntent) = phase,
                  intent == nil || intent == currentIntent
            else { return .ignore }
            return .stop(currentIntent)
        }
    }
}

private extension CaptureLifecyclePhase {
    var isTerminalFailure: Bool {
        switch self {
        case .stopped, .explanationDeclined, .recoveryFailed,
             .processDiscoveryFailed, .routeMonitoringFailed, .failed, .verifiedFailure,
             .cleanupFailed:
            true
        case .ready, .installingRouteMonitor, .explaining, .preparing, .active,
             .stopping, .suspending, .suspended, .recovering:
            false
        }
    }
}

extension CaptureLifecyclePhase {
    var resumableIntent: CaptureIntent? {
        switch self {
        case let .installingRouteMonitor(intent), let .explaining(intent),
             let .preparing(intent), let .active(intent),
             let .suspending(intent), let .suspended(intent),
             let .recovering(intent, _), let .recoveryFailed(intent, _),
             let .verifiedFailure(intent):
            intent
        case let .stopping(intent), let .processDiscoveryFailed(intent),
             let .routeMonitoringFailed(intent), let .failed(intent):
            intent
        case .stopped, .explanationDeclined, .ready, .cleanupFailed:
            nil
        }
    }

    fileprivate func updatingLevelingSettings(
        _ settings: LevelingSettings
    ) -> CaptureLifecyclePhase {
        func updated(_ intent: CaptureIntent) -> CaptureIntent {
            intent.replacingLevelingSettings(settings)
        }

        switch self {
        case let .installingRouteMonitor(intent):
            return .installingRouteMonitor(updated(intent))
        case let .explaining(intent):
            return .explaining(updated(intent))
        case let .preparing(intent):
            return .preparing(updated(intent))
        case let .active(intent):
            return .active(updated(intent))
        case let .stopping(intent):
            return .stopping(intent.map(updated))
        case let .suspending(intent):
            return .suspending(updated(intent))
        case let .suspended(intent):
            return .suspended(updated(intent))
        case let .recovering(intent, reason):
            return .recovering(updated(intent), reason)
        case let .recoveryFailed(intent, failure):
            return .recoveryFailed(updated(intent), failure)
        case let .processDiscoveryFailed(intent):
            return .processDiscoveryFailed(intent.map(updated))
        case let .routeMonitoringFailed(intent):
            return .routeMonitoringFailed(intent.map(updated))
        case let .failed(intent):
            return .failed(intent.map(updated))
        case let .verifiedFailure(intent):
            return .verifiedFailure(updated(intent))
        case .stopped, .explanationDeclined, .ready, .cleanupFailed:
            return self
        }
    }
}
