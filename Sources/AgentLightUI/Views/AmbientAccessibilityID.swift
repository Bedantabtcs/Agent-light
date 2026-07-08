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
    static let settingsReconnect = "settings.light.reconnect"
    static let settingsReplaceDevice = "settings.light.replaceDevice"
    static let settingsRepair = "settings.integrations.repair"
    static let settingsConfirmRepair = "settings.integrations.confirmRepair"
    static let settingsUninstall = "settings.integrations.uninstall"
    static let settingsConfirmCodexTrust = "settings.integrations.confirmCodexTrust"
    static let settingsResetOwnershipReceipt = "settings.integrations.resetOwnershipReceipt"
    static let settingsEnableLogin = "settings.general.enableLogin"
    static let settingsRetryLoginStatus = "settings.general.retryLoginStatus"
    static let settingsMonitoring = "settings.general.monitoring"

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
        settingsReconnect,
        settingsReplaceDevice,
        settingsRepair,
        settingsConfirmRepair,
        settingsUninstall,
        settingsConfirmCodexTrust,
        settingsResetOwnershipReceipt,
        settingsMonitoring,
        settingsEnableLogin,
        settingsRetryLoginStatus
    ]
}
