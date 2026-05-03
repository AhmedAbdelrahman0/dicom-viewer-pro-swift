import Foundation

/// Builds a `PETAttenuationCorrector` from a cohort job + AC catalog entry,
/// without touching the `@MainActor`-isolated `PETACViewModel`. The cohort
/// processor runs on a background actor and needs a `Sendable` factory that
/// takes plain config values.
///
/// Mirrors `CohortClassifierFactory`. Changes to the per-study factory in
/// `PETACViewModel.makeCorrector(for:)` should land here too — duplication
/// over extraction, deliberate, same reason as for classifiers.
enum CohortPETACFactory {

    static func make(job: CohortJob,
                     entry: PETACCatalog.Entry) throws -> PETAttenuationCorrector {
        switch entry.backend {
        case .subprocess:
            let script = job.petACScriptPath.trimmingCharacters(in: .whitespaces)
            guard !script.isEmpty else {
                throw PETACError.modelUnavailable("Cohort AC script path is empty.")
            }
            let env = parseEnvironment(job.petACEnvironment)
            let args = parseArgs(job.petACExtraArgs)
            let spec = SubprocessPETACCorrector.Spec(
                executablePath: (job.petACPythonExecutable as NSString).expandingTildeInPath,
                scriptPath: (script as NSString).expandingTildeInPath,
                arguments: args,
                environment: env,
                timeoutSeconds: job.petACTimeoutSeconds,
                requiresAnatomicalChannel: entry.requiresAnatomicalChannel
            )
            return SubprocessPETACCorrector(
                id: entry.id,
                displayName: entry.displayName,
                spec: spec,
                provenance: entry.provenance,
                license: entry.license
            )

        case .dgxRemote:
            let cfg = DGXSparkConfig.load()
            guard cfg.isConfigured, cfg.enabled else {
                throw PETACError.modelUnavailable(
                    "Remote workstation not configured / enabled for cohort AC."
                )
            }
            let script = job.petACScriptPath.trimmingCharacters(in: .whitespaces)
            guard !script.isEmpty else {
                throw PETACError.modelUnavailable("Cohort AC remote script path is empty.")
            }
            // First env line of the form `activate=…` becomes the activation
            // command (matches RemoteLesionClassifier + PETACViewModel).
            let activation = job.petACEnvironment
                .split(separator: "\n")
                .first { $0.hasPrefix("activate=") }
                .map { String($0.dropFirst("activate=".count)) } ?? ""
            let spec = RemotePETACCorrector.Spec(
                dgx: cfg,
                remoteScriptPath: script,
                activationCommand: activation,
                scriptArguments: parseArgs(job.petACExtraArgs),
                timeoutSeconds: job.petACTimeoutSeconds,
                requiresAnatomicalChannel: entry.requiresAnatomicalChannel
            )
            return RemotePETACCorrector(
                id: entry.id,
                displayName: "\(entry.displayName) · remote",
                spec: spec,
                provenance: entry.provenance,
                license: entry.license
            )
        }
    }

    private static func parseEnvironment(_ raw: String) -> [String: String] {
        raw.split(separator: "\n")
            .reduce(into: [:]) { acc, line in
                let pieces = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pieces.count == 2 { acc[pieces[0]] = pieces[1] }
            }
    }

    private static func parseArgs(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
