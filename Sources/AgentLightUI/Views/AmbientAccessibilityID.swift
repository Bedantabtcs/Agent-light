enum AmbientAccessibilityID {
    static let onboardingEndpoint = "onboarding.endpoint"
    static let onboardingAccessID = "onboarding.accessID"
    static let onboardingAccessSecret = "onboarding.accessSecret"
    static let onboardingDeviceID = "onboarding.deviceID"
    static let onboardingVerify = "onboarding.verifyConnect"
    static let integrationApprove = "integrationReview.approve"
    static let monitorPause = "monitor.pause"
    static let monitorResume = "monitor.resume"
    static let monitorRepair = "monitor.repair"
    static let monitorSettings = "monitor.settings"
    static let monitorQuit = "monitor.quit"
    static let settingsBack = "settings.back"
    static let settingsDisconnect = "settings.light.disconnect"
    static let settingsRepair = "settings.integrations.repair"
    static let settingsEnableLogin = "settings.general.enableLogin"

    static let interactive: [String] = [
        onboardingEndpoint,
        onboardingAccessID,
        onboardingAccessSecret,
        onboardingDeviceID,
        onboardingVerify,
        integrationApprove,
        monitorPause,
        monitorResume,
        monitorRepair,
        monitorSettings,
        monitorQuit,
        settingsBack,
        settingsDisconnect,
        settingsRepair,
        settingsEnableLogin
    ]
}
