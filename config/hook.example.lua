-- Embedded near the top of the generated single-file Hook.
-- Edit here and rebuild to preserve settings across future builds, or edit the
-- generated file's CONFIG section directly for a one-off deployment.
return {
    route = "auto", -- mission_a_do_script / mission_direct / server_direct also supported.
    pollHz = 1,
    maxResponseBytes = 262144,
    maxPendingItems = 2048,
    maxPendingBytes = 8388608,
    manualAckEnabled = false, -- Explicit local testing only; never means C++ persisted data.
    diagnosticsEnabled = false,
    network = { enabled = false, host = "127.0.0.1", port = 9081,
        instanceId = "dcs-local", token = "", ackMode = "memory" },
    -- outputDirectory = "E:/DcsEsportCapture",
    -- Resume only after verifying the existing collector belongs to this running mission:
    -- resumeSource = { missionSessionId = "...", collectorEpoch = "..." },
    collector = {
        revision = 1,
        scope = { coalitions = { "red", "blue", "neutral" }, includeAirplanes = true,
            includeHelicopters = false, missileScope = "all" },
        sampling = { aircraftHz = 1, missileHz = 1, slowFieldsHz = 1, reconcileIntervalSec = 5 },
        eventBuffer = { maxCount = 10000, maxBytes = 16777216 }
    }
}
