import AppKit
import Combine
import Sparkle

/// Sparkle owns the release-notes/consent/download/verification/install flow.
/// Automatic checks are distinct from downloads; automatic installation is forbidden.
@MainActor final class AppUpdateStore: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status = "每天静默检查；有新版时在 App 内提示。"
    @Published private(set) var availableVersion: String?
    @Published private(set) var availableNotes = ""
    @Published private(set) var hasUpdateBadge = false
    @Published private(set) var installationWaiting = false
    var prepareForInstallation: (() async -> Bool)?
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var availableBuild: String?
    private let preferences: UserDefaults?
    private let hostBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    init(live: Bool = true) {
        preferences = live ? .standard : nil
        super.init()
        guard live else { return }
        if let cached = preferences?.dictionary(forKey: "updates.notice.v1"), cached["hostBuild"] as? String == hostBuild,
           let version = cached["version"] as? String, let build = cached["build"] as? String,
           let notes = cached["notes"] as? String {
            availableVersion = version; availableBuild = build; availableNotes = notes
            hasUpdateBadge = preferences?.string(forKey: "updates.seenBuild.v1") != build
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }
    func start() {
        guard let updater = controller?.updater else { return }
        do { try updater.start() }
        catch { status = "更新检查暂不可用：" + error.localizedDescription; return }
        // Prevent an older preference from opting users into silent installation.
        if updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = false }
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.automaticChecks = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).sink { [weak self] in self?.lastChecked = $0 }.store(in: &subscriptions)
    }
    func checkNow() {
        guard let updater = controller?.updater else { return }
        guard !updater.sessionInProgress else { return }
        status = "正在检查更新…"
        updater.checkForUpdateInformation()
    }
    func installAvailableUpdate() { markUpdateSeen(); controller?.checkForUpdates(nil) }
    func markUpdateSeen() {
        hasUpdateBadge = false
        if let availableBuild { preferences?.set(availableBuild, forKey: "updates.seenBuild.v1") }
    }
    func setAutomaticChecks(_ value: Bool) { controller?.updater.automaticallyChecksForUpdates = value }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        publishNotice(item)
    }
    private func publishNotice(_ item: SUAppcastItem) {
        availableVersion = item.displayVersionString; availableBuild = item.versionString
        if item.itemDescriptionFormat == "plain-text" || item.itemDescriptionFormat == "markdown" {
            availableNotes = item.itemDescription ?? "此版本的更新说明可在安装确认页查看。"
        } else { availableNotes = "此版本的完整更新说明可在安装确认页查看。" }
        hasUpdateBadge = preferences?.string(forKey: "updates.seenBuild.v1") != item.versionString
        preferences?.set(["hostBuild": hostBuild, "version": item.displayVersionString, "build": item.versionString, "notes": availableNotes], forKey: "updates.notice.v1")
        status = "发现新版本 " + item.displayVersionString + "，可先查看更新内容，再决定是否安装。"
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = "当前已经是最新版本。"; availableVersion = nil; availableBuild = nil; availableNotes = ""; hasUpdateBadge = false
        preferences?.removeObject(forKey: "updates.notice.v1")
    }
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Task { @MainActor [weak self] in self?.publishNotice(update) }
    }
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor [weak self] in self?.markUpdateSeen() }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == 1001 { return }
        status = "本次更新检查未完成：" + error.localizedDescription
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstall = installHandler
        resumeInstallation()
        return true
    }
    func resumeInstallation() {
        guard let pendingInstall, !installationWaiting else { return }
        installationWaiting = true
        Task { @MainActor in
            let ready = await prepareForInstallation?() ?? false
            installationWaiting = false
            guard ready else {
                status = "更新尚未安装：请先处理未保存配置或设备恢复提示，再点击重试安装。"
                return
            }
            self.pendingInstall = nil
            pendingInstall()
        }
    }
    var canRetryInstallation: Bool { pendingInstall != nil && !installationWaiting }
}
