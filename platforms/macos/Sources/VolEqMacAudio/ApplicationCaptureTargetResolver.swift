// SPDX-License-Identifier: MPL-2.0

enum ApplicationCaptureTargetResolver {
    static func resolve(
        identity: ApplicationCaptureIdentity,
        processes: [AudioProcess]
    ) -> ApplicationTargetResolution {
        guard !identity.bundleID.isEmpty else { return .missing }
        if let exact = processes.first(where: {
            $0.pid == identity.pid && $0.bundleID == identity.bundleID
        }) {
            return .resolved(exact)
        }

        let bundleMatches = processes.filter { $0.bundleID == identity.bundleID }
        guard bundleMatches.count == 1, let match = bundleMatches.first else {
            return bundleMatches.isEmpty ? .missing : .ambiguous
        }
        return .resolved(match)
    }
}
