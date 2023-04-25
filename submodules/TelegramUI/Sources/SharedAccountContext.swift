import Foundation
import UIKit
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import Display
import TelegramPresentationData
import TelegramCallsUI
import TelegramUIPreferences
import AccountContext
import DeviceLocationManager
import LegacyUI
import ChatListUI
import PeersNearbyUI
import PeerInfoUI
import SettingsUI
import UrlHandling
import LegacyMediaPickerUI
import LocalMediaResources
import OverlayStatusController
import AlertUI
import PresentationDataUtils
import LocationUI
import AppLock
import WallpaperBackgroundNode
import InAppPurchaseManager
import PremiumUI
import StickerPackPreviewUI
import ChatControllerInteraction
import ChatPresentationInterfaceState
import StorageUsageScreen
import DebugSettingsUI
import TextFormat
import ChatTextLinkEditUI
import AttachmentTextInputPanelNode
import ChatEntityKeyboardInputNode

private final class AccountUserInterfaceInUseContext {
    let subscribers = Bag<(Bool) -> Void>()
    let tokens = Bag<Void>()
    
    var isEmpty: Bool {
        return self.tokens.isEmpty && self.subscribers.isEmpty
    }
}

private struct AccountAttributes: Equatable {
    let sortIndex: Int32
    let isTestingEnvironment: Bool
    let backupData: AccountBackupData?
}

private enum AddedAccountResult {
    case upgrading(Float)
    case ready(AccountRecordId, Account?, Int32, LimitsConfiguration?, ContentSettings?, AppConfiguration?)
}

private enum AddedAccountsResult {
    case upgrading(Float)
    case ready([(AccountRecordId, Account?, Int32, LimitsConfiguration?, ContentSettings?, AppConfiguration?)])
}

private var testHasInstance = false

public final class SharedAccountContextImpl: SharedAccountContext {
    public let mainWindow: Window1?
    public let applicationBindings: TelegramApplicationBindings
    public let sharedContainerPath: String
    public let basePath: String
    public let accountManager: AccountManager<TelegramAccountManagerTypes>
    public let appLockContext: AppLockContext
    
    private let navigateToChatImpl: (AccountRecordId, PeerId, MessageId?) -> Void
    
    private let apsNotificationToken: Signal<Data?, NoError>
    private let voipNotificationToken: Signal<Data?, NoError>
    
    public let firebaseSecretStream: Signal<[String: String], NoError>
    
    private let authorizationPushConfigurationValue = Promise<AuthorizationCodePushNotificationConfiguration?>(nil)
    public var authorizationPushConfiguration: Signal<AuthorizationCodePushNotificationConfiguration?, NoError> {
        return self.authorizationPushConfigurationValue.get()
    }
    
    private var activeAccountsValue: (primary: AccountContext?, accounts: [(AccountRecordId, AccountContext, Int32)], currentAuth: UnauthorizedAccount?)?
    private let activeAccountsPromise = Promise<(primary: AccountContext?, accounts: [(AccountRecordId, AccountContext, Int32)], currentAuth: UnauthorizedAccount?)>()
    public var activeAccountContexts: Signal<(primary: AccountContext?, accounts: [(AccountRecordId, AccountContext, Int32)], currentAuth: UnauthorizedAccount?), NoError> {
        return self.activeAccountsPromise.get()
    }
    private let managedAccountDisposables = DisposableDict<AccountRecordId>()
    private let activeAccountsWithInfoPromise = Promise<(primary: AccountRecordId?, accounts: [AccountWithInfo])>()
    public var activeAccountsWithInfo: Signal<(primary: AccountRecordId?, accounts: [AccountWithInfo]), NoError> {
        return self.activeAccountsWithInfoPromise.get()
    }
    
    private var activeUnauthorizedAccountValue: UnauthorizedAccount?
    private let activeUnauthorizedAccountPromise = Promise<UnauthorizedAccount?>()
    public var activeUnauthorizedAccount: Signal<UnauthorizedAccount?, NoError> {
        return self.activeUnauthorizedAccountPromise.get()
    }
    
    private let registeredNotificationTokensDisposable = MetaDisposable()
    
    public let mediaManager: MediaManager
    public let contactDataManager: DeviceContactDataManager?
    public let locationManager: DeviceLocationManager?
    public var callManager: PresentationCallManager?
    let hasInAppPurchases: Bool
    
    private var callDisposable: Disposable?
    private var callStateDisposable: Disposable?
    
    private(set) var currentCallStatusBarNode: CallStatusBarNodeImpl?
    
    private var groupCallDisposable: Disposable?
    
    private var callController: CallController?
    public let hasOngoingCall = ValuePromise<Bool>(false)
    private let callState = Promise<PresentationCallState?>(nil)
    
    private var groupCallController: VoiceChatController?
    public var currentGroupCallController: ViewController? {
        return self.groupCallController
    }
    private let hasGroupCallOnScreenPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    public var hasGroupCallOnScreen: Signal<Bool, NoError> {
        return self.hasGroupCallOnScreenPromise.get()
    }
    
    private var immediateHasOngoingCallValue = Atomic<Bool>(value: false)
    public var immediateHasOngoingCall: Bool {
        return self.immediateHasOngoingCallValue.with { $0 }
    }
    private var hasOngoingCallDisposable: Disposable?
    
    public let enablePreloads = Promise<Bool>()
    public let hasPreloadBlockingContent = Promise<Bool>(false)
    
    private var accountUserInterfaceInUseContexts: [AccountRecordId: AccountUserInterfaceInUseContext] = [:]
    
    var switchingData: (settingsController: (SettingsController & ViewController)?, chatListController: ChatListController?, chatListBadge: String?) = (nil, nil, nil)
    
    private let _currentPresentationData: Atomic<PresentationData>
    public var currentPresentationData: Atomic<PresentationData> {
        return self._currentPresentationData
    }
    private let _presentationData = Promise<PresentationData>()
    public var presentationData: Signal<PresentationData, NoError> {
        return self._presentationData.get()
    }
    private let presentationDataDisposable = MetaDisposable()
    
    public let currentInAppNotificationSettings: Atomic<InAppNotificationSettings>
    private var inAppNotificationSettingsDisposable: Disposable?
    
    public var currentAutomaticMediaDownloadSettings: MediaAutoDownloadSettings
    private let _automaticMediaDownloadSettings = Promise<MediaAutoDownloadSettings>()
    public var automaticMediaDownloadSettings: Signal<MediaAutoDownloadSettings, NoError> {
        return self._automaticMediaDownloadSettings.get()
    }
    
    public private(set) var energyUsageSettings: EnergyUsageSettings
    
    public let currentAutodownloadSettings: Atomic<AutodownloadSettings>
    private let _autodownloadSettings = Promise<AutodownloadSettings>()
    private var currentAutodownloadSettingsDisposable = MetaDisposable()
    
    public let currentMediaInputSettings: Atomic<MediaInputSettings>
    private var mediaInputSettingsDisposable: Disposable?
    
    public let currentMediaDisplaySettings: Atomic<MediaDisplaySettings>
    private var mediaDisplaySettingsDisposable: Disposable?
    
    public let currentStickerSettings: Atomic<StickerSettings>
    private var stickerSettingsDisposable: Disposable?
    
    private let automaticMediaDownloadSettingsDisposable = MetaDisposable()
    
    private var immediateExperimentalUISettingsValue = Atomic<ExperimentalUISettings>(value: ExperimentalUISettings.defaultSettings)
    public var immediateExperimentalUISettings: ExperimentalUISettings {
        return self.immediateExperimentalUISettingsValue.with { $0 }
    }
    private var experimentalUISettingsDisposable: Disposable?
    
    public var presentGlobalController: (ViewController, Any?) -> Void = { _, _ in }
    public var presentCrossfadeController: () -> Void = {}
    
    private let displayUpgradeProgress: (Float?) -> Void
    
    private var spotlightDataContext: SpotlightDataContext?
    private var widgetDataContext: WidgetDataContext?
    
    private weak var appDelegate: AppDelegate?
    
    private var invalidatedApsToken: Data?
    
    private let energyUsageAutomaticDisposable = MetaDisposable()
    
    init(mainWindow: Window1?, sharedContainerPath: String, basePath: String, encryptionParameters: ValueBoxEncryptionParameters, accountManager: AccountManager<TelegramAccountManagerTypes>, appLockContext: AppLockContext, applicationBindings: TelegramApplicationBindings, initialPresentationDataAndSettings: InitialPresentationDataAndSettings, networkArguments: NetworkInitializationArguments, hasInAppPurchases: Bool, rootPath: String, legacyBasePath: String?, apsNotificationToken: Signal<Data?, NoError>, voipNotificationToken: Signal<Data?, NoError>, firebaseSecretStream: Signal<[String: String], NoError>, setNotificationCall: @escaping (PresentationCall?) -> Void, navigateToChat: @escaping (AccountRecordId, PeerId, MessageId?) -> Void, displayUpgradeProgress: @escaping (Float?) -> Void = { _ in }, appDelegate: AppDelegate?) {
        assert(Queue.mainQueue().isCurrent())
        
        precondition(!testHasInstance)
        testHasInstance = true
        
        self.appDelegate = appDelegate
        self.mainWindow = mainWindow
        self.applicationBindings = applicationBindings
        self.sharedContainerPath = sharedContainerPath
        self.basePath = basePath
        self.accountManager = accountManager
        self.navigateToChatImpl = navigateToChat
        self.displayUpgradeProgress = displayUpgradeProgress
        self.appLockContext = appLockContext
        self.hasInAppPurchases = hasInAppPurchases
        
        self.accountManager.mediaBox.fetchCachedResourceRepresentation = { (resource, representation) -> Signal<CachedMediaResourceRepresentationResult, NoError> in
            return fetchCachedSharedResourceRepresentation(accountManager: accountManager, resource: resource, representation: representation)
        }
        
        self.apsNotificationToken = apsNotificationToken
        self.voipNotificationToken = voipNotificationToken
        
        self.firebaseSecretStream = firebaseSecretStream
        
        self.authorizationPushConfigurationValue.set(apsNotificationToken |> map { data -> AuthorizationCodePushNotificationConfiguration? in
            guard let data else {
                return nil
            }
            let sandbox: Bool
            #if DEBUG
            sandbox = true
            #else
            sandbox = false
            #endif
            return AuthorizationCodePushNotificationConfiguration(
                token: hexString(data),
                isSandbox: sandbox
            )
        })
                
        if applicationBindings.isMainApp {
            self.locationManager = DeviceLocationManager(queue: Queue.mainQueue())
            self.contactDataManager = DeviceContactDataManagerImpl()
        } else {
            self.locationManager = nil
            self.contactDataManager = nil
        }
        
        self._currentPresentationData = Atomic(value: initialPresentationDataAndSettings.presentationData)
        self.currentAutomaticMediaDownloadSettings = initialPresentationDataAndSettings.automaticMediaDownloadSettings
        self.currentAutodownloadSettings = Atomic(value: initialPresentationDataAndSettings.autodownloadSettings)
        self.currentMediaInputSettings = Atomic(value: initialPresentationDataAndSettings.mediaInputSettings)
        self.currentMediaDisplaySettings = Atomic(value: initialPresentationDataAndSettings.mediaDisplaySettings)
        self.currentStickerSettings = Atomic(value: initialPresentationDataAndSettings.stickerSettings)
        self.currentInAppNotificationSettings = Atomic(value: initialPresentationDataAndSettings.inAppNotificationSettings)
        
        if automaticEnergyUsageShouldBeOnNow(settings: self.currentAutomaticMediaDownloadSettings) {
            self.energyUsageSettings = EnergyUsageSettings.powerSavingDefault
        } else {
            self.energyUsageSettings = self.currentAutomaticMediaDownloadSettings.energyUsageSettings
        }
        
        let presentationData: Signal<PresentationData, NoError> = .single(initialPresentationDataAndSettings.presentationData)
        |> then(
            updatedPresentationData(accountManager: self.accountManager, applicationInForeground: self.applicationBindings.applicationInForeground, systemUserInterfaceStyle: mainWindow?.systemUserInterfaceStyle ?? .single(.light))
        )
        self._presentationData.set(presentationData)
        self._automaticMediaDownloadSettings.set(.single(initialPresentationDataAndSettings.automaticMediaDownloadSettings)
        |> then(accountManager.sharedData(keys: [SharedDataKeys.autodownloadSettings, ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings])
            |> map { sharedData in
                let autodownloadSettings: AutodownloadSettings = sharedData.entries[SharedDataKeys.autodownloadSettings]?.get(AutodownloadSettings.self) ?? .defaultSettings
                let automaticDownloadSettings: MediaAutoDownloadSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings]?.get(MediaAutoDownloadSettings.self) ?? .defaultSettings
                return automaticDownloadSettings.updatedWithAutodownloadSettings(autodownloadSettings)
            }
        ))
        
        self.mediaManager = MediaManagerImpl(accountManager: accountManager, inForeground: applicationBindings.applicationInForeground, presentationData: presentationData)
        
        self.mediaManager.overlayMediaManager.updatePossibleEmbeddingItem = { [weak self] item in
            guard let strongSelf = self else {
                return
            }
            guard let navigationController = strongSelf.mainWindow?.viewController as? NavigationController else {
                return
            }
            var content: NavigationControllerDropContent?
            if let item = item {
                content = NavigationControllerDropContent(
                    position: item.position,
                    item: VideoNavigationControllerDropContentItem(
                        itemNode: item.itemNode
                    )
                )
            }
            
            navigationController.updatePossibleControllerDropContent(content: content)
        }
        
        self.mediaManager.overlayMediaManager.embedPossibleEmbeddingItem = { [weak self] item in
            guard let strongSelf = self else {
                return false
            }
            guard let navigationController = strongSelf.mainWindow?.viewController as? NavigationController else {
                return false
            }
            let content = NavigationControllerDropContent(
                position: item.position,
                item: VideoNavigationControllerDropContentItem(
                    itemNode: item.itemNode
                )
            )
            
            return navigationController.acceptPossibleControllerDropContent(content: content)
        }
        
        self._autodownloadSettings.set(.single(initialPresentationDataAndSettings.autodownloadSettings)
        |> then(accountManager.sharedData(keys: [SharedDataKeys.autodownloadSettings])
            |> map { sharedData in
                let autodownloadSettings: AutodownloadSettings = sharedData.entries[SharedDataKeys.autodownloadSettings]?.get(AutodownloadSettings.self) ?? .defaultSettings
                return autodownloadSettings
            }
        ))
        
        self.presentationDataDisposable.set((self.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] next in
            if let strongSelf = self {
                var stringsUpdated = false
                var themeUpdated = false
                var themeNameUpdated = false
                let _ = strongSelf.currentPresentationData.modify { current in
                    if next.strings !== current.strings {
                        stringsUpdated = true
                    }
                    if next.theme !== current.theme {
                        themeUpdated = true
                    }
                    if next.theme.name != current.theme.name {
                        themeNameUpdated = true
                    }
                    return next
                }
                if stringsUpdated {
                    updateLegacyLocalization(strings: next.strings)
                }
                if themeUpdated {
                    updateLegacyTheme()
                }
                if themeNameUpdated {
                    strongSelf.presentCrossfadeController()
                }
            }
        }))
        
        self.inAppNotificationSettingsDisposable = (self.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            if let strongSelf = self {
                if let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) {
                    let _ = strongSelf.currentInAppNotificationSettings.swap(settings)
                }
            }
        })
        
        self.mediaInputSettingsDisposable = (self.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.mediaInputSettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            if let strongSelf = self {
                if let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.mediaInputSettings]?.get(MediaInputSettings.self) {
                    let _ = strongSelf.currentMediaInputSettings.swap(settings)
                }
            }
        })
        
        self.mediaDisplaySettingsDisposable = (self.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.mediaDisplaySettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            if let strongSelf = self {
                if let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.mediaDisplaySettings]?.get(MediaDisplaySettings.self) {
                    let _ = strongSelf.currentMediaDisplaySettings.swap(settings)
                }
            }
        })
        
        self.stickerSettingsDisposable = (self.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.stickerSettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            if let strongSelf = self {
                if let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.stickerSettings]?.get(StickerSettings.self) {
                    let _ = strongSelf.currentStickerSettings.swap(settings)
                }
            }
        })
        
        let immediateExperimentalUISettingsValue = self.immediateExperimentalUISettingsValue
        let _ = immediateExperimentalUISettingsValue.swap(initialPresentationDataAndSettings.experimentalUISettings)
        self.experimentalUISettingsDisposable = (self.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.experimentalUISettings])
        |> deliverOnMainQueue).start(next: { sharedData in
            if let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) {
                let _ = immediateExperimentalUISettingsValue.swap(settings)
            }
        })
        
        let _ = self.contactDataManager?.personNameDisplayOrder().start(next: { order in
            let _ = updateContactSettingsInteractively(accountManager: accountManager, { settings in
                var settings = settings
                settings.nameDisplayOrder = order
                return settings
            }).start()
        })
        
        self.automaticMediaDownloadSettingsDisposable.set(self._automaticMediaDownloadSettings.get().start(next: { [weak self] next in
            if let strongSelf = self {
                strongSelf.currentAutomaticMediaDownloadSettings = next
                
                if automaticEnergyUsageShouldBeOnNow(settings: next) {
                    strongSelf.energyUsageSettings = EnergyUsageSettings.powerSavingDefault
                } else {
                    strongSelf.energyUsageSettings = next.energyUsageSettings
                }
                strongSelf.energyUsageAutomaticDisposable.set((automaticEnergyUsageShouldBeOn(settings: next)
                |> deliverOnMainQueue).start(next: { value in
                    if let strongSelf = self {
                        if value {
                            strongSelf.energyUsageSettings = EnergyUsageSettings.powerSavingDefault
                        } else {
                            strongSelf.energyUsageSettings = next.energyUsageSettings
                        }
                    }
                }))
            }
        }))
        
        self.currentAutodownloadSettingsDisposable.set(self._autodownloadSettings.get().start(next: { [weak self] next in
            if let strongSelf = self {
                let _ = strongSelf.currentAutodownloadSettings.swap(next)
            }
        }))
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let differenceDisposable = MetaDisposable()
        let _ = (accountManager.accountRecords()
        |> map { view -> (AccountRecordId?, [AccountRecordId: AccountAttributes], (AccountRecordId, Bool)?) in
            print("SharedAccountContextImpl: records appeared in \(CFAbsoluteTimeGetCurrent() - startTime)")
            
            var result: [AccountRecordId: AccountAttributes] = [:]
            for record in view.records {
                let isLoggedOut = record.attributes.contains(where: { attribute in
                    if case .loggedOut = attribute {
                        return true
                    } else {
                        return false
                    }
                })
                if isLoggedOut {
                    continue
                }
                let isTestingEnvironment = record.attributes.contains(where: { attribute in
                    if case let .environment(environment) = attribute, case .test = environment.environment {
                        return true
                    } else {
                        return false
                    }
                })
                var backupData: AccountBackupData?
                var sortIndex: Int32 = 0
                for attribute in record.attributes {
                    if case let .sortOrder(sortOrder) = attribute {
                        sortIndex = sortOrder.order
                    } else if case let .backupData(backupDataValue) = attribute {
                        backupData = backupDataValue.data
                    }
                }
                result[record.id] = AccountAttributes(sortIndex: sortIndex, isTestingEnvironment: isTestingEnvironment, backupData: backupData)
            }
            let authRecord: (AccountRecordId, Bool)? = view.currentAuthAccount.flatMap({ authAccount in
                let isTestingEnvironment = authAccount.attributes.contains(where: { attribute in
                    if case let .environment(environment) = attribute, case .test = environment.environment {
                        return true
                    } else {
                        return false
                    }
                })
                return (authAccount.id, isTestingEnvironment)
            })
            return (view.currentRecord?.id, result, authRecord)
        }
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            if lhs.0 != rhs.0 {
                return false
            }
            if lhs.1 != rhs.1 {
                return false
            }
            if lhs.2?.0 != rhs.2?.0 {
                return false
            }
            if lhs.2?.1 != rhs.2?.1 {
                return false
            }
            return true
        })
        |> deliverOnMainQueue).start(next: { primaryId, records, authRecord in
            var addedSignals: [Signal<AddedAccountResult, NoError>] = []
            var addedAuthSignal: Signal<UnauthorizedAccount?, NoError> = .single(nil)
            for (id, attributes) in records {
                if self.activeAccountsValue?.accounts.firstIndex(where: { $0.0 == id}) == nil {
                    addedSignals.append(accountWithId(accountManager: accountManager, networkArguments: networkArguments, id: id, encryptionParameters: encryptionParameters, supplementary: !applicationBindings.isMainApp, rootPath: rootPath, beginWithTestingEnvironment: attributes.isTestingEnvironment, backupData: attributes.backupData, auxiliaryMethods: makeTelegramAccountAuxiliaryMethods(appDelegate: appDelegate))
                    |> mapToSignal { result -> Signal<AddedAccountResult, NoError> in
                        switch result {
                            case let .authorized(account):
                                setupAccount(account, fetchCachedResourceRepresentation: fetchCachedResourceRepresentation, transformOutgoingMessageMedia: transformOutgoingMessageMedia)
                                return TelegramEngine(account: account).data.get(
                                    TelegramEngine.EngineData.Item.Configuration.Limits(),
                                    TelegramEngine.EngineData.Item.Configuration.ContentSettings(),
                                    TelegramEngine.EngineData.Item.Configuration.App()
                                )
                                |> map { limitsConfiguration, contentSettings, appConfiguration -> AddedAccountResult in
                                    return .ready(id, account, attributes.sortIndex, limitsConfiguration._asLimits(), contentSettings, appConfiguration)
                                }
                            case let .upgrading(progress):
                                return .single(.upgrading(progress))
                            default:
                                return .single(.ready(id, nil, attributes.sortIndex, nil, nil, nil))
                        }
                    })
                }
            }
            if let authRecord = authRecord, authRecord.0 != self.activeAccountsValue?.currentAuth?.id {
                addedAuthSignal = accountWithId(accountManager: accountManager, networkArguments: networkArguments, id: authRecord.0, encryptionParameters: encryptionParameters, supplementary: !applicationBindings.isMainApp, rootPath: rootPath, beginWithTestingEnvironment: authRecord.1, backupData: nil, auxiliaryMethods: makeTelegramAccountAuxiliaryMethods(appDelegate: appDelegate))
                |> mapToSignal { result -> Signal<UnauthorizedAccount?, NoError> in
                    switch result {
                        case let .unauthorized(account):
                            return .single(account)
                        case .upgrading:
                            return .complete()
                        default:
                            return .single(nil)
                    }
                }
            }
            
            let mappedAddedAccounts = combineLatest(queue: .mainQueue(), addedSignals)
            |> map { results -> AddedAccountsResult in
                var readyAccounts: [(AccountRecordId, Account?, Int32, LimitsConfiguration?, ContentSettings?, AppConfiguration?)] = []
                var totalProgress: Float = 0.0
                var hasItemsWithProgress = false
                for result in results {
                    switch result {
                        case let .ready(id, account, sortIndex, limitsConfiguration, contentSettings, appConfiguration):
                            readyAccounts.append((id, account, sortIndex, limitsConfiguration, contentSettings, appConfiguration))
                            totalProgress += 1.0
                        case let .upgrading(progress):
                            hasItemsWithProgress = true
                            totalProgress += progress
                    }
                }
                if hasItemsWithProgress, !results.isEmpty {
                    return .upgrading(totalProgress / Float(results.count))
                } else {
                    return .ready(readyAccounts)
                }
            }
            
            differenceDisposable.set((combineLatest(queue: .mainQueue(), mappedAddedAccounts, addedAuthSignal)
            |> deliverOnMainQueue).start(next: { mappedAddedAccounts, authAccount in
                print("SharedAccountContextImpl: accounts processed in \(CFAbsoluteTimeGetCurrent() - startTime)")
                
                var addedAccounts: [(AccountRecordId, Account?, Int32, LimitsConfiguration?, ContentSettings?, AppConfiguration?)] = []
                switch mappedAddedAccounts {
                    case let .upgrading(progress):
                        self.displayUpgradeProgress(progress)
                        return
                    case let .ready(value):
                        addedAccounts = value
                }
                
                self.displayUpgradeProgress(nil)
                
                var hadUpdates = false
                if self.activeAccountsValue == nil {
                    self.activeAccountsValue = (nil, [], nil)
                    hadUpdates = true
                }
                
                struct AccountPeerKey: Hashable {
                    let peerId: PeerId
                    let isTestingEnvironment: Bool
                }
                
                var existingAccountPeerKeys = Set<AccountPeerKey>()
                for accountRecord in addedAccounts {
                    if let account = accountRecord.1 {
                        if existingAccountPeerKeys.contains(AccountPeerKey(peerId: account.peerId, isTestingEnvironment: account.testingEnvironment)) {
                            let _ = accountManager.transaction({ transaction in
                                transaction.updateRecord(accountRecord.0, { _ in
                                    return nil
                                })
                            }).start()
                        } else {
                            existingAccountPeerKeys.insert(AccountPeerKey(peerId: account.peerId, isTestingEnvironment: account.testingEnvironment))
                            if let index = self.activeAccountsValue?.accounts.firstIndex(where: { $0.0 == account.id }) {
                                self.activeAccountsValue?.accounts.remove(at: index)
                                self.managedAccountDisposables.set(nil, forKey: account.id)
                                assertionFailure()
                            }

                            let context = AccountContextImpl(sharedContext: self, account: account, limitsConfiguration: accountRecord.3 ?? .defaultValue, contentSettings: accountRecord.4 ?? .default, appConfiguration: accountRecord.5 ?? .defaultValue)

                            self.activeAccountsValue!.accounts.append((account.id, context, accountRecord.2))
                            
                            self.managedAccountDisposables.set(self.updateAccountBackupData(account: account).start(), forKey: account.id)
                            account.resetStateManagement()
                            hadUpdates = true
                        }
                    } else {
                        let _ = accountManager.transaction({ transaction in
                            transaction.updateRecord(accountRecord.0, { _ in
                                return nil
                            })
                        }).start()
                    }
                }
                var removedIds: [AccountRecordId] = []
                for id in self.activeAccountsValue!.accounts.map({ $0.0 }) {
                    if records[id] == nil {
                        removedIds.append(id)
                    }
                }
                for id in removedIds {
                    hadUpdates = true
                    if let index = self.activeAccountsValue?.accounts.firstIndex(where: { $0.0 == id }) {
                        self.activeAccountsValue?.accounts.remove(at: index)
                        self.managedAccountDisposables.set(nil, forKey: id)
                    }
                }
                var primary: AccountContext?
                if let primaryId = primaryId {
                    if let index = self.activeAccountsValue?.accounts.firstIndex(where: { $0.0 == primaryId }) {
                        primary = self.activeAccountsValue?.accounts[index].1
                    }
                }
                if primary == nil && !self.activeAccountsValue!.accounts.isEmpty {
                    primary = self.activeAccountsValue!.accounts.first?.1
                }
                if primary !== self.activeAccountsValue!.primary {
                    hadUpdates = true
                    self.activeAccountsValue!.primary?.account.postbox.clearCaches()
                    self.activeAccountsValue!.primary?.account.resetCachedData()
                    self.activeAccountsValue!.primary = primary
                }
                if self.activeAccountsValue!.currentAuth?.id != authRecord?.0 {
                    hadUpdates = true
                    self.activeAccountsValue!.currentAuth?.postbox.clearCaches()
                    self.activeAccountsValue!.currentAuth = nil
                }
                if let authAccount = authAccount {
                    hadUpdates = true
                    self.activeAccountsValue!.currentAuth = authAccount
                }
                if hadUpdates {
                    self.activeAccountsValue!.accounts.sort(by: { $0.2 < $1.2 })
                    self.activeAccountsPromise.set(.single(self.activeAccountsValue!))
                    
                    self.performAccountSettingsImportIfNecessary()
                }
                
                if self.activeAccountsValue!.primary == nil && self.activeAccountsValue!.currentAuth == nil {
                    self.beginNewAuth(testingEnvironment: false)
                }
            }))
        })
        
        self.activeAccountsWithInfoPromise.set(self.activeAccountContexts
        |> mapToSignal { primary, accounts, _ -> Signal<(primary: AccountRecordId?, accounts: [AccountWithInfo]), NoError> in
            return combineLatest(accounts.map { _, context, _ -> Signal<AccountWithInfo?, NoError> in
                return context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
                |> map { peer -> AccountWithInfo? in
                    guard let peer = peer else {
                        return nil
                    }
                    return AccountWithInfo(account: context.account, peer: peer._asPeer())
                }
                |> distinctUntilChanged
            })
            |> map { accountsWithInfo -> (primary: AccountRecordId?, accounts: [AccountWithInfo]) in
                var accountsWithInfoResult: [AccountWithInfo] = []
                for info in accountsWithInfo {
                    if let info = info {
                        accountsWithInfoResult.append(info)
                    }
                }
                return (primary?.account.id, accountsWithInfoResult)
            }
        })
        
        if let mainWindow = mainWindow, applicationBindings.isMainApp {
            let callManager = PresentationCallManagerImpl(accountManager: self.accountManager, getDeviceAccessData: {
                return (self.currentPresentationData.with { $0 }, { [weak self] c, a in
                    self?.presentGlobalController(c, a)
                }, {
                    applicationBindings.openSettings()
                })
            }, isMediaPlaying: { [weak self] in
                guard let strongSelf = self else {
                    return false
                }
                var result = false
                let _ = (strongSelf.mediaManager.globalMediaPlayerState
                |> take(1)
                |> deliverOnMainQueue).start(next: { state in
                    if let (_, playbackState, _) = state, case let .state(value) = playbackState, case .playing = value.status.status {
                        result = true
                    }
                })
                return result
            }, resumeMediaPlayback: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.mediaManager.playlistControl(.playback(.play), type: nil)
            }, audioSession: self.mediaManager.audioSession, activeAccounts: self.activeAccountContexts |> map { _, accounts, _ in
                return Array(accounts.map({ $0.1 }))
            })
            self.callManager = callManager
            
            self.callDisposable = (callManager.currentCallSignal
            |> deliverOnMainQueue).start(next: { [weak self] call in
                if let strongSelf = self {
                    if call !== strongSelf.callController?.call {
                        strongSelf.callController?.dismiss()
                        strongSelf.callController = nil
                        strongSelf.hasOngoingCall.set(false)
                        
                        if let call = call {
                            mainWindow.hostView.containerView.endEditing(true)
                            let callController = CallController(sharedContext: strongSelf, account: call.context.account, call: call, easyDebugAccess: !GlobalExperimentalSettings.isAppStoreBuild)
                            strongSelf.callController = callController
                            strongSelf.mainWindow?.present(callController, on: .calls)
                            strongSelf.callState.set(call.state
                            |> map(Optional.init))
                            strongSelf.hasOngoingCall.set(true)
                            setNotificationCall(call)
                        } else {
                            strongSelf.callState.set(.single(nil))
                            strongSelf.hasOngoingCall.set(false)
                            setNotificationCall(nil)
                        }
                    }
                }
            })
            
            self.groupCallDisposable = (callManager.currentGroupCallSignal
            |> deliverOnMainQueue).start(next: { [weak self] call in
                if let strongSelf = self {
                    if call !== strongSelf.groupCallController?.call {
                        strongSelf.groupCallController?.dismiss(closing: true, manual: false)
                        strongSelf.groupCallController = nil
                        strongSelf.hasOngoingCall.set(false)
                        
                        if let call = call, let navigationController = mainWindow.viewController as? NavigationController {
                            mainWindow.hostView.containerView.endEditing(true)
                            
                            if call.isStream {
                                strongSelf.hasGroupCallOnScreenPromise.set(true)
                                let groupCallController = MediaStreamComponentController(call: call)
                                groupCallController.onViewDidAppear = { [weak self] in
                                    if let strongSelf = self {
                                        strongSelf.hasGroupCallOnScreenPromise.set(true)
                                    }
                                }
                                groupCallController.onViewDidDisappear = { [weak self] in
                                    if let strongSelf = self {
                                        strongSelf.hasGroupCallOnScreenPromise.set(false)
                                    }
                                }
                                groupCallController.navigationPresentation = .flatModal
                                groupCallController.parentNavigationController = navigationController
                                strongSelf.groupCallController = groupCallController
                                navigationController.pushViewController(groupCallController)
                            } else {
                                strongSelf.hasGroupCallOnScreenPromise.set(true)
                                let groupCallController = VoiceChatControllerImpl(sharedContext: strongSelf, accountContext: call.accountContext, call: call)
                                groupCallController.onViewDidAppear = { [weak self] in
                                    if let strongSelf = self {
                                        strongSelf.hasGroupCallOnScreenPromise.set(true)
                                    }
                                }
                                groupCallController.onViewDidDisappear = { [weak self] in
                                    if let strongSelf = self {
                                        strongSelf.hasGroupCallOnScreenPromise.set(false)
                                    }
                                }
                                groupCallController.navigationPresentation = .flatModal
                                groupCallController.parentNavigationController = navigationController
                                strongSelf.groupCallController = groupCallController
                                navigationController.pushViewController(groupCallController)
                            }
                                
                            strongSelf.hasOngoingCall.set(true)
                        } else {
                            strongSelf.hasOngoingCall.set(false)
                        }
                    }
                }
            })
            
            let callSignal: Signal<PresentationCall?, NoError> = .single(nil)
            |> then(
                callManager.currentCallSignal
            )
            let groupCallSignal: Signal<PresentationGroupCall?, NoError> = .single(nil)
            |> then(
                callManager.currentGroupCallSignal
            )
            
            self.callStateDisposable = combineLatest(queue: .mainQueue(),
                callSignal,
                groupCallSignal,
                self.hasGroupCallOnScreenPromise.get()
            ).start(next: { [weak self] call, groupCall, hasGroupCallOnScreen in
                if let strongSelf = self {
                    let statusBarContent: CallStatusBarNodeImpl.Content?
                    if let call = call {
                        statusBarContent = .call(strongSelf, call.context.account, call)
                    } else if let groupCall = groupCall, !hasGroupCallOnScreen {
                        statusBarContent = .groupCall(strongSelf, groupCall.account, groupCall)
                    } else {
                        statusBarContent = nil
                    }
                    
                    var resolvedCallStatusBarNode: CallStatusBarNodeImpl?
                    if let statusBarContent = statusBarContent {
                        if let current = strongSelf.currentCallStatusBarNode {
                            resolvedCallStatusBarNode = current
                        } else {
                            resolvedCallStatusBarNode = CallStatusBarNodeImpl()
                            strongSelf.currentCallStatusBarNode = resolvedCallStatusBarNode
                        }
                        resolvedCallStatusBarNode?.update(content: statusBarContent)
                    } else {
                        strongSelf.currentCallStatusBarNode = nil
                    }
                    
                    if let navigationController = strongSelf.mainWindow?.viewController as? NavigationController {
                        navigationController.setForceInCallStatusBar(resolvedCallStatusBarNode)
                    }
                }
            })
            
            mainWindow.inCallNavigate = { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                if let callController = strongSelf.callController {
                    if callController.isNodeLoaded {
                        mainWindow.hostView.containerView.endEditing(true)
                        if callController.view.superview == nil {
                            mainWindow.present(callController, on: .calls)
                        } else {
                            callController.expandFromPipIfPossible()
                        }
                    }
                } else if let groupCallController = strongSelf.groupCallController {
                    if groupCallController.isNodeLoaded {
                        mainWindow.hostView.containerView.endEditing(true)
                        if groupCallController.view.superview == nil {
                            (mainWindow.viewController as? NavigationController)?.pushViewController(groupCallController)
                        }
                    }
                }
            }
        } else {
            self.callManager = nil
        }
        
        let immediateHasOngoingCallValue = self.immediateHasOngoingCallValue
        self.hasOngoingCallDisposable = self.hasOngoingCall.get().start(next: { value in
            let _ = immediateHasOngoingCallValue.swap(value)
        })
        
        self.enablePreloads.set(combineLatest(
            self.hasOngoingCall.get(),
            self.hasPreloadBlockingContent.get()
        )
        |> map { hasOngoingCall, hasPreloadBlockingContent -> Bool in
            if hasOngoingCall {
                return false
            }
            if hasPreloadBlockingContent {
                return false
            }
            return true
        })
        
        let _ = managedCleanupAccounts(networkArguments: networkArguments, accountManager: self.accountManager, rootPath: rootPath, auxiliaryMethods: makeTelegramAccountAuxiliaryMethods(appDelegate: appDelegate), encryptionParameters: encryptionParameters).start()
        
        self.updateNotificationTokensRegistration()
        
        if applicationBindings.isMainApp {
            self.widgetDataContext = WidgetDataContext(basePath: self.basePath, inForeground: self.applicationBindings.applicationInForeground, activeAccounts: self.activeAccountContexts
            |> map { _, accounts, _ in
                return accounts.map { $0.1.account }
            }, presentationData: self.presentationData, appLockContext: self.appLockContext as! AppLockContextImpl)
            
            let enableSpotlight = accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.intentsSettings]))
            |> map { sharedData -> Bool in
                let intentsSettings: IntentsSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.intentsSettings]?.get(IntentsSettings.self) ?? .defaultSettings
                return intentsSettings.contacts
            }
            |> distinctUntilChanged
            self.spotlightDataContext = SpotlightDataContext(appBasePath: applicationBindings.containerPath, accountManager: accountManager, accounts: combineLatest(enableSpotlight, self.activeAccountContexts
            |> map { _, accounts, _ in
                return accounts.map { _, account, _ in
                    return account.account
                }
            }) |> map { enableSpotlight, accounts in
                if enableSpotlight {
                    return accounts
                } else {
                    return []
                }
            })
        }
    }
    
    deinit {
        assertionFailure("SharedAccountContextImpl is not supposed to be deallocated")
        self.registeredNotificationTokensDisposable.dispose()
        self.presentationDataDisposable.dispose()
        self.automaticMediaDownloadSettingsDisposable.dispose()
        self.currentAutodownloadSettingsDisposable.dispose()
        self.inAppNotificationSettingsDisposable?.dispose()
        self.mediaInputSettingsDisposable?.dispose()
        self.mediaDisplaySettingsDisposable?.dispose()
        self.callDisposable?.dispose()
        self.groupCallDisposable?.dispose()
        self.callStateDisposable?.dispose()
    }
    
    private var didPerformAccountSettingsImport = false
    private func performAccountSettingsImportIfNecessary() {
        if self.didPerformAccountSettingsImport {
            return
        }
        if let _ = UserDefaults.standard.value(forKey: "didPerformAccountSettingsImport") {
            self.didPerformAccountSettingsImport = true
            return
        }
        UserDefaults.standard.set(true as NSNumber, forKey: "didPerformAccountSettingsImport")
        UserDefaults.standard.synchronize()
        
        if let primary = self.activeAccountsValue?.primary {
            let _ = (primary.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: primary.account.peerId))
            |> deliverOnMainQueue).start(next: { [weak self] peer in
                guard let self, case let .user(user) = peer else {
                    return
                }
                if user.isPremium {
                    let _ = updateMediaDownloadSettingsInteractively(accountManager: self.accountManager, { settings in
                        var settings = settings
                        settings.energyUsageSettings.loopEmoji = true
                        return settings
                    }).start()
                }
            })
        }
        
        self.didPerformAccountSettingsImport = true
    }
    
    private func updateAccountBackupData(account: Account) -> Signal<Never, NoError> {
        return accountBackupData(postbox: account.postbox)
        |> mapToSignal { backupData -> Signal<Never, NoError> in
            guard let backupData = backupData else {
                return .complete()
            }
            return self.accountManager.transaction { transaction -> Void in
                transaction.updateRecord(account.id, { record in
                    guard let record = record else {
                        return nil
                    }
                    var attributes: [TelegramAccountManagerTypes.Attribute] = record.attributes.filter { attribute in
                        if case .backupData = attribute {
                            return false
                        } else {
                            return true
                        }
                    }
                    attributes.append(.backupData(AccountBackupDataAttribute(data: backupData)))
                    return AccountRecord(id: record.id, attributes: attributes, temporarySessionId: record.temporarySessionId)
                })
            }
            |> ignoreValues
        }
    }
    
    public func updateNotificationTokensRegistration() {
        let sandbox: Bool
        #if DEBUG
        sandbox = true
        #else
        sandbox = false
        #endif
        
        let settings = self.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings])
        |> map { sharedData -> (allAccounts: Bool, includeMuted: Bool) in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? InAppNotificationSettings.defaultSettings
            return (settings.displayNotificationsFromAllAccounts, false)
        }
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            if lhs.allAccounts != rhs.allAccounts {
                return false
            }
            if lhs.includeMuted != rhs.includeMuted {
                return false
            }
            return true
        })
        
        let updatedApsToken = self.apsNotificationToken |> distinctUntilChanged(isEqual: { $0 == $1 })
        self.registeredNotificationTokensDisposable.set((combineLatest(
            queue: .mainQueue(),
            settings,
            self.activeAccountContexts,
            updatedApsToken
        )
        |> mapToSignal { settings, activeAccountsAndInfo, apsNotificationToken -> Signal<(Bool, Data?), NoError> in
            let (primary, activeAccounts, _) = activeAccountsAndInfo
            var appliedApsList: [Signal<Bool?, NoError>] = []
            var appliedVoipList: [Signal<Never, NoError>] = []
            var activeProductionUserIds = activeAccounts.map({ $0.1 }).filter({ !$0.account.testingEnvironment }).map({ $0.account.peerId.id })
            var activeTestingUserIds = activeAccounts.map({ $0.1 }).filter({ $0.account.testingEnvironment }).map({ $0.account.peerId.id })
            
            let allProductionUserIds = activeProductionUserIds
            let allTestingUserIds = activeTestingUserIds
            
            if !settings.allAccounts {
                if let primary = primary {
                    if !primary.account.testingEnvironment {
                        activeProductionUserIds = [primary.account.peerId.id]
                        activeTestingUserIds = []
                    } else {
                        activeProductionUserIds = []
                        activeTestingUserIds = [primary.account.peerId.id]
                    }
                } else {
                    activeProductionUserIds = []
                    activeTestingUserIds = []
                }
            }
            
            for (_, account, _) in activeAccounts {
                let appliedAps: Signal<Bool, NoError>
                let appliedVoip: Signal<Never, NoError>
                
                if !activeProductionUserIds.contains(account.account.peerId.id) && !activeTestingUserIds.contains(account.account.peerId.id) {
                    if let apsNotificationToken {
                        appliedAps = account.engine.accountData.unregisterNotificationToken(token: apsNotificationToken, type: .aps(encrypt: false), otherAccountUserIds: (account.account.testingEnvironment ? allTestingUserIds : allProductionUserIds).filter({ $0 != account.account.peerId.id }))
                        |> map { _ -> Bool in
                        }
                        |> then(.single(true))
                    } else {
                        appliedAps = .single(true)
                    }
                    
                    appliedVoip = self.voipNotificationToken
                    |> distinctUntilChanged(isEqual: { $0 == $1 })
                    |> mapToSignal { token -> Signal<Never, NoError> in
                        guard let token = token else {
                            return .complete()
                        }
                        return account.engine.accountData.unregisterNotificationToken(token: token, type: .voip, otherAccountUserIds: (account.account.testingEnvironment ? allTestingUserIds : allProductionUserIds).filter({ $0 != account.account.peerId.id }))
                    }
                } else {
                    if let apsNotificationToken {
                        appliedAps = account.engine.accountData.registerNotificationToken(token: apsNotificationToken, type: .aps(encrypt: true), sandbox: sandbox, otherAccountUserIds: (account.account.testingEnvironment ? activeTestingUserIds : activeProductionUserIds).filter({ $0 != account.account.peerId.id }), excludeMutedChats: !settings.includeMuted)
                    } else {
                        appliedAps = .single(true)
                    }
                    appliedVoip = self.voipNotificationToken
                    |> distinctUntilChanged(isEqual: { $0 == $1 })
                    |> mapToSignal { token -> Signal<Never, NoError> in
                        guard let token = token else {
                            return .complete()
                        }
                        return account.engine.accountData.registerNotificationToken(token: token, type: .voip, sandbox: sandbox, otherAccountUserIds: (account.account.testingEnvironment ? activeTestingUserIds : activeProductionUserIds).filter({ $0 != account.account.peerId.id }), excludeMutedChats: !settings.includeMuted)
                        |> ignoreValues
                    }
                }
                
                appliedApsList.append(Signal<Bool?, NoError>.single(nil) |> then(appliedAps |> map(Optional.init)))
                appliedVoipList.append(appliedVoip)
            }
            
            let allApsSuccess = combineLatest(appliedApsList)
            |> map { values -> Bool in
                return !values.contains(false)
            }
            
            let allVoipSuccess = combineLatest(appliedVoipList)
            
            return combineLatest(
                allApsSuccess,
                Signal<Void, NoError>.single(Void())
                |> then(
                    allVoipSuccess
                    |> map { _ -> Void in
                        return Void()
                    }
                )
            )
            |> map { allApsSuccess, _ -> (Bool, Data?) in
                return (allApsSuccess, apsNotificationToken)
            }
        }
        |> deliverOnMainQueue).start(next: { [weak self] allApsSuccess, apsToken in
            guard let self, let appDelegate = self.appDelegate else {
                return
            }
            if !allApsSuccess {
                if self.invalidatedApsToken != apsToken {
                    self.invalidatedApsToken = apsToken
                    
                    appDelegate.requestNotificationTokenInvalidation()
                }
            }
        }))
    }
    
    public func beginNewAuth(testingEnvironment: Bool) {
        let _ = self.accountManager.transaction({ transaction -> Void in
            let _ = transaction.createAuth([.environment(AccountEnvironmentAttribute(environment: testingEnvironment ? .test : .production))])
        }).start()
    }
    
    public func switchToAccount(id: AccountRecordId, fromSettingsController settingsController: ViewController? = nil, withChatListController chatListController: ViewController? = nil) {
        if self.activeAccountsValue?.primary?.account.id == id {
            return
        }
        
        assert(Queue.mainQueue().isCurrent())
        var chatsBadge: String?
        if let rootController = self.mainWindow?.viewController as? TelegramRootController {
            if let tabsController = rootController.viewControllers.first as? TabBarController {
                for controller in tabsController.controllers {
                    if let controller = controller as? ChatListController {
                        chatsBadge = controller.tabBarItem.badgeValue
                    }
                }
                
                if let chatListController = chatListController {
                    if let index = tabsController.controllers.firstIndex(where: { $0 is ChatListController }) {
                        var controllers = tabsController.controllers
                        controllers[index] = chatListController
                        tabsController.setControllers(controllers, selectedIndex: index)
                    }
                }
            }
        }
        self.switchingData = (settingsController as? (ViewController & SettingsController), chatListController as? ChatListController, chatsBadge)
        
        let _ = self.accountManager.transaction({ transaction -> Bool in
            if transaction.getCurrent()?.0 != id {
                transaction.setCurrentId(id)
                return true
            } else {
                return false
            }
        }).start(next: { value in
            if !value {
                self.switchingData = (nil, nil, nil)
            }
        })
    }
    
    public func openSearch(filter: ChatListSearchFilter, query: String?) {
        if let rootController = self.mainWindow?.viewController as? TelegramRootController {
            rootController.openChatsController(activateSearch: true, filter: filter, query: query)
        }
    }
    
    public func navigateToChat(accountId: AccountRecordId, peerId: PeerId, messageId: MessageId?) {
        self.navigateToChatImpl(accountId, peerId, messageId)
    }
    
    public func messageFromPreloadedChatHistoryViewForLocation(id: MessageId, location: ChatHistoryLocationInput, context: AccountContext, chatLocation: ChatLocation, subject: ChatControllerSubject?, chatLocationContextHolder: Atomic<ChatLocationContextHolder?>, tagMask: MessageTags?) -> Signal<(MessageIndex?, Bool), NoError> {
        let historyView = preloadedChatHistoryViewForLocation(location, context: context, chatLocation: chatLocation, subject: subject, chatLocationContextHolder: chatLocationContextHolder, fixedCombinedReadStates: nil, tagMask: tagMask, additionalData: [])
        return historyView
        |> mapToSignal { historyView -> Signal<(MessageIndex?, Bool), NoError> in
            switch historyView {
            case .Loading:
                return .single((nil, true))
            case let .HistoryView(view, _, _, _, _, _, _):
                for entry in view.entries {
                    if entry.message.id == id {
                        return .single((entry.message.index, false))
                    }
                }
                return .single((nil, false))
            }
        }
        |> take(until: { index in
            return SignalTakeAction(passthrough: true, complete: !index.1)
        })
    }
    
    public func makeOverlayAudioPlayerController(context: AccountContext, chatLocation: ChatLocation, type: MediaManagerPlayerType, initialMessageId: MessageId, initialOrder: MusicPlaybackSettingsOrder, playlistLocation: SharedMediaPlaylistLocation?, parentNavigationController: NavigationController?) -> ViewController & OverlayAudioPlayerController {
        return OverlayAudioPlayerControllerImpl(context: context, chatLocation: chatLocation, type: type, initialMessageId: initialMessageId, initialOrder: initialOrder, playlistLocation: playlistLocation, parentNavigationController: parentNavigationController)
    }
    
    public func makeTempAccountContext(account: Account) -> AccountContext {
        return AccountContextImpl(sharedContext: self, account: account, limitsConfiguration: .defaultValue, contentSettings: .default, appConfiguration: .defaultValue, temp: true)
    }
    
    public func openChatMessage(_ params: OpenChatMessageParams) -> Bool {
        return openChatMessageImpl(params)
    }
    
    public func navigateToCurrentCall() {
        guard let mainWindow = self.mainWindow else {
            return
        }
        if let callController = self.callController {
            if callController.isNodeLoaded && callController.view.superview == nil {
                mainWindow.hostView.containerView.endEditing(true)
                mainWindow.present(callController, on: .calls)
            }
        } else if let groupCallController = self.groupCallController {
            if groupCallController.isNodeLoaded && groupCallController.view.superview == nil {
                mainWindow.hostView.containerView.endEditing(true)
                (mainWindow.viewController as? NavigationController)?.pushViewController(groupCallController)
            }
        }
    }
    
    public func accountUserInterfaceInUse(_ id: AccountRecordId) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let context: AccountUserInterfaceInUseContext
            if let current = self.accountUserInterfaceInUseContexts[id] {
                context = current
            } else {
                context = AccountUserInterfaceInUseContext()
                self.accountUserInterfaceInUseContexts[id] = context
            }
            
            subscriber.putNext(!context.tokens.isEmpty)
            let index = context.subscribers.add({ value in
                subscriber.putNext(value)
            })
            
            return ActionDisposable { [weak context] in
                Queue.mainQueue().async {
                    if let current = self.accountUserInterfaceInUseContexts[id], current === context {
                        current.subscribers.remove(index)
                        if current.isEmpty {
                            self.accountUserInterfaceInUseContexts.removeValue(forKey: id)
                        }
                    }
                }
            }
        }
        |> runOn(Queue.mainQueue())
    }
    
    public func setAccountUserInterfaceInUse(_ id: AccountRecordId) -> Disposable {
        assert(Queue.mainQueue().isCurrent())
        let context: AccountUserInterfaceInUseContext
        if let current = self.accountUserInterfaceInUseContexts[id] {
            context = current
        } else {
            context = AccountUserInterfaceInUseContext()
            self.accountUserInterfaceInUseContexts[id] = context
        }
        
        let wasEmpty = context.tokens.isEmpty
        let index = context.tokens.add(Void())
        if wasEmpty {
            for f in context.subscribers.copyItems() {
                f(true)
            }
        }
        
        return ActionDisposable { [weak context] in
            Queue.mainQueue().async {
                if let current = self.accountUserInterfaceInUseContexts[id], current === context {
                    let wasEmpty = current.tokens.isEmpty
                    current.tokens.remove(index)
                    if current.tokens.isEmpty && !wasEmpty {
                        for f in current.subscribers.copyItems() {
                            f(false)
                        }
                    }
                    if current.isEmpty {
                        self.accountUserInterfaceInUseContexts.removeValue(forKey: id)
                    }
                }
            }
        }
    }
    
    public func handleTextLinkAction(context: AccountContext, peerId: PeerId?, navigateDisposable: MetaDisposable, controller: ViewController, action: TextLinkItemActionType, itemLink: TextLinkItem) {
        handleTextLinkActionImpl(context: context, peerId: peerId, navigateDisposable: navigateDisposable, controller: controller, action: action, itemLink: itemLink)
    }
    
    public func makePeerInfoController(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)?, peer: Peer, mode: PeerInfoControllerMode, avatarInitiallyExpanded: Bool, fromChat: Bool, requestsContext: PeerInvitationImportersContext?) -> ViewController? {
        let controller = peerInfoControllerImpl(context: context, updatedPresentationData: updatedPresentationData, peer: peer, mode: mode, avatarInitiallyExpanded: avatarInitiallyExpanded, isOpenedFromChat: fromChat)
        controller?.navigationPresentation = .modalInLargeLayout
        return controller
    }
    
    public func makeChannelAdminController(context: AccountContext, peerId: PeerId, adminId: PeerId, initialParticipant: ChannelParticipant) -> ViewController? {
        let controller = channelAdminController(context: context, peerId: peerId, adminId: adminId, initialParticipant: initialParticipant, updated: { _ in }, upgradedToSupergroup: { _, _ in }, transferedOwnership: { _ in })
        return controller
    }
    
    public func makeDebugSettingsController(context: AccountContext?) -> ViewController? {
        let controller = debugController(sharedContext: self, context: context)
        return controller
    }
    
    public func openExternalUrl(context: AccountContext, urlContext: OpenURLContext, url: String, forceExternal: Bool, presentationData: PresentationData, navigationController: NavigationController?, dismissInput: @escaping () -> Void) {
        openExternalUrlImpl(context: context, urlContext: urlContext, url: url, forceExternal: forceExternal, presentationData: presentationData, navigationController: navigationController, dismissInput: dismissInput)
    }
    
    public func chatAvailableMessageActions(engine: TelegramEngine, accountPeerId: EnginePeer.Id, messageIds: Set<EngineMessage.Id>) -> Signal<ChatAvailableMessageActions, NoError> {
        return chatAvailableMessageActionsImpl(engine: engine, accountPeerId: accountPeerId, messageIds: messageIds)
    }
    
    public func chatAvailableMessageActions(engine: TelegramEngine, accountPeerId: EnginePeer.Id, messageIds: Set<EngineMessage.Id>, messages: [EngineMessage.Id: EngineMessage] = [:], peers: [EnginePeer.Id: EnginePeer] = [:]) -> Signal<ChatAvailableMessageActions, NoError> {
        return chatAvailableMessageActionsImpl(engine: engine, accountPeerId: accountPeerId, messageIds: messageIds, messages: messages.mapValues({ $0._asMessage() }), peers: peers.mapValues({ $0._asPeer() }))
    }
    
    public func navigateToChatController(_ params: NavigateToChatControllerParams) {
        navigateToChatControllerImpl(params)
    }
    
    public func navigateToForumChannel(context: AccountContext, peerId: EnginePeer.Id, navigationController: NavigationController) {
        navigateToForumChannelImpl(context: context, peerId: peerId, navigationController: navigationController)
    }
    
    public func navigateToForumThread(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64, messageId: EngineMessage.Id?, navigationController: NavigationController, activateInput: ChatControllerActivateInput?, keepStack: NavigateToChatKeepStack) -> Signal<Never, NoError> {
        return navigateToForumThreadImpl(context: context, peerId: peerId, threadId: threadId, messageId: messageId, navigationController: navigationController, activateInput: activateInput, keepStack: keepStack)
    }
    
    public func chatControllerForForumThread(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64) -> Signal<ChatController, NoError> {
        return chatControllerForForumThreadImpl(context: context, peerId: peerId, threadId: threadId)
    }
    
    public func openStorageUsage(context: AccountContext) {
        guard let navigationController = self.mainWindow?.viewController as? NavigationController else {
            return
        }
        let controller = StorageUsageScreen(context: context, makeStorageUsageExceptionsScreen: { category in
            return storageUsageExceptionsScreen(context: context, category: category)
        })
        navigationController.pushViewController(controller)
    }
    
    public func openLocationScreen(context: AccountContext, messageId: MessageId, navigationController: NavigationController) {
        var found = false
        for controller in navigationController.viewControllers.reversed() {
            if let controller = controller as? LocationViewController, controller.subject.id.peerId == messageId.peerId {
                controller.goToUserLocation(visibleRadius: nil)
                found = true
                break
            }
        }
        
        if !found {
            let controllerParams = LocationViewParams(sendLiveLocation: { location in
                //let outMessage: EnqueueMessage = .message(text: "", attributes: [], mediaReference: .standalone(media: location), replyToMessageId: nil, localGroupingKey: nil, correlationId: nil)
//                params.enqueueMessage(outMessage)
            }, stopLiveLocation: { messageId in
                if let messageId = messageId {
                    context.liveLocationManager?.cancelLiveLocation(peerId: messageId.peerId)
                }
            }, openUrl: { _ in }, openPeer: { peer in
//                params.openPeer(peer, .info)
            })
            
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> deliverOnMainQueue).start(next: { message in
                guard let message = message else {
                    return
                }
                let controller = LocationViewController(context: context, subject: message, params: controllerParams)
                controller.navigationPresentation = .modal
                navigationController.pushViewController(controller)
            })
        }
    }
    
    public func resolveUrl(context: AccountContext, peerId: PeerId?, url: String, skipUrlAuth: Bool) -> Signal<ResolvedUrl, NoError> {
        return resolveUrlImpl(context: context, peerId: peerId, url: url, skipUrlAuth: skipUrlAuth)
    }
    
    public func openResolvedUrl(_ resolvedUrl: ResolvedUrl, context: AccountContext, urlContext: OpenURLContext, navigationController: NavigationController?, forceExternal: Bool, openPeer: @escaping (EnginePeer, ChatControllerInteractionNavigateToPeer) -> Void, sendFile: ((FileMediaReference) -> Void)?, sendSticker: ((FileMediaReference, UIView, CGRect) -> Bool)?, requestMessageActionUrlAuth: ((MessageActionUrlSubject) -> Void)?, joinVoiceChat: ((PeerId, String?, CachedChannelData.ActiveCall) -> Void)?, present: @escaping (ViewController, Any?) -> Void, dismissInput: @escaping () -> Void, contentContext: Any?) {
        openResolvedUrlImpl(resolvedUrl, context: context, urlContext: urlContext, navigationController: navigationController, forceExternal: forceExternal, openPeer: openPeer, sendFile: sendFile, sendSticker: sendSticker, requestMessageActionUrlAuth: requestMessageActionUrlAuth, joinVoiceChat: joinVoiceChat, present: present, dismissInput: dismissInput, contentContext: contentContext)
    }
    
    public func makeDeviceContactInfoController(context: AccountContext, subject: DeviceContactInfoSubject, completed: (() -> Void)?, cancelled: (() -> Void)?) -> ViewController {
        return deviceContactInfoController(context: context, subject: subject, completed: completed, cancelled: cancelled)
    }
    
    public func makePeersNearbyController(context: AccountContext) -> ViewController {
        return peersNearbyController(context: context)
    }
    
    public func makeChatController(context: AccountContext, chatLocation: ChatLocation, subject: ChatControllerSubject?, botStart: ChatControllerInitialBotStart?, mode: ChatControllerPresentationMode) -> ChatController {
        return ChatControllerImpl(context: context, chatLocation: chatLocation, subject: subject, botStart: botStart, mode: mode)
    }
    
    public func makePeerSharedMediaController(context: AccountContext, peerId: PeerId) -> ViewController? {
        return nil
    }
    
    public func makeChatRecentActionsController(context: AccountContext, peer: Peer, adminPeerId: PeerId?) -> ViewController {
        return ChatRecentActionsController(context: context, peer: peer, adminPeerId: adminPeerId)
    }
    
    public func presentContactsWarningSuppression(context: AccountContext, present: (ViewController, Any?) -> Void) {
        presentContactsWarningSuppressionImpl(context: context, present: present)
    }
    
    public func makeContactSelectionController(_ params: ContactSelectionControllerParams) -> ContactSelectionController {
        return ContactSelectionControllerImpl(params)
    }
    
    public func makeContactMultiselectionController(_ params: ContactMultiselectionControllerParams) -> ContactMultiselectionController {
        return ContactMultiselectionControllerImpl(params)
    }
    
    public func makeComposeController(context: AccountContext) -> ViewController {
        return ComposeControllerImpl(context: context)
    }
    
    public func makeProxySettingsController(context: AccountContext) -> ViewController {
        return proxySettingsController(context: context)
    }
    
    public func makeLocalizationListController(context: AccountContext) -> ViewController {
        return LocalizationListController(context: context)
    }
    
    public func openAddContact(context: AccountContext, firstName: String, lastName: String, phoneNumber: String, label: String, present: @escaping (ViewController, Any?) -> Void, pushController: @escaping (ViewController) -> Void, completed: @escaping () -> Void) {
        openAddContactImpl(context: context, firstName: firstName, lastName: lastName, phoneNumber: phoneNumber, label: label, present: present, pushController: pushController, completed: completed)
    }
    
    public func openAddPersonContact(context: AccountContext, peerId: PeerId, pushController: @escaping (ViewController) -> Void, present: @escaping (ViewController, Any?) -> Void) {
        openAddPersonContactImpl(context: context, peerId: peerId, pushController: pushController, present: present)
    }
    
    public func makeCreateGroupController(context: AccountContext, peerIds: [PeerId], initialTitle: String?, mode: CreateGroupMode, completion: ((PeerId, @escaping () -> Void) -> Void)?) -> ViewController {
        return createGroupControllerImpl(context: context, peerIds: peerIds, initialTitle: initialTitle, mode: mode, completion: completion)
    }
    
    public func makeChatListController(context: AccountContext, location: ChatListControllerLocation, controlsHistoryPreload: Bool, hideNetworkActivityStatus: Bool, previewing: Bool, enableDebugActions: Bool) -> ChatListController {
        return ChatListControllerImpl(context: context, location: location, controlsHistoryPreload: controlsHistoryPreload, hideNetworkActivityStatus: hideNetworkActivityStatus, previewing: previewing, enableDebugActions: enableDebugActions)
    }
    
    public func makePeerSelectionController(_ params: PeerSelectionControllerParams) -> PeerSelectionController {
        return PeerSelectionControllerImpl(params)
    }
    
    public func openAddPeerMembers(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)?, parentController: ViewController, groupPeer: Peer, selectAddMemberDisposable: MetaDisposable, addMemberDisposable: MetaDisposable) {
        return presentAddMembersImpl(context: context, updatedPresentationData: updatedPresentationData, parentController: parentController, groupPeer: groupPeer, selectAddMemberDisposable: selectAddMemberDisposable, addMemberDisposable: addMemberDisposable)
    }
    
    public func makeChatMessagePreviewItem(context: AccountContext, messages: [Message], theme: PresentationTheme, strings: PresentationStrings, wallpaper: TelegramWallpaper, fontSize: PresentationFontSize, chatBubbleCorners: PresentationChatBubbleCorners, dateTimeFormat: PresentationDateTimeFormat, nameOrder: PresentationPersonNameOrder, forcedResourceStatus: FileMediaResourceStatus?, tapMessage: ((Message) -> Void)?, clickThroughMessage: (() -> Void)? = nil, backgroundNode: ASDisplayNode?, availableReactions: AvailableReactions?, isCentered: Bool) -> ListViewItem {
        let controllerInteraction: ChatControllerInteraction

        controllerInteraction = ChatControllerInteraction(openMessage: { _, _ in
            return false }, openPeer: { _, _, _, _ in }, openPeerMention: { _ in }, openMessageContextMenu: { _, _, _, _, _, _ in }, openMessageReactionContextMenu: { _, _, _, _ in
            }, updateMessageReaction: { _, _ in }, activateMessagePinch: { _ in
            }, openMessageContextActions: { _, _, _, _ in }, navigateToMessage: { _, _ in }, navigateToMessageStandalone: { _ in
            }, navigateToThreadMessage: { _, _, _ in
            }, tapMessage: { message in
                tapMessage?(message)
        }, clickThroughMessage: {
            clickThroughMessage?()
        }, toggleMessagesSelection: { _, _ in }, sendCurrentMessage: { _ in }, sendMessage: { _ in }, sendSticker: { _, _, _, _, _, _, _, _, _ in return false }, sendEmoji: { _, _, _ in }, sendGif: { _, _, _, _, _ in return false }, sendBotContextResultAsGif: { _, _, _, _, _, _ in
            return false
        }, requestMessageActionCallback: { _, _, _, _ in }, requestMessageActionUrlAuth: { _, _ in }, activateSwitchInline: { _, _, _ in }, openUrl: { _, _, _, _ in }, shareCurrentLocation: {}, shareAccountContact: {}, sendBotCommand: { _, _ in }, openInstantPage: { _, _ in  }, openWallpaper: { _ in  }, openTheme: { _ in  }, openHashtag: { _, _ in }, updateInputState: { _ in }, updateInputMode: { _ in }, openMessageShareMenu: { _ in
        }, presentController: { _, _ in
        }, presentControllerInCurrent: { _, _ in
        }, navigationController: {
            return nil
        }, chatControllerNode: {
            return nil
        }, presentGlobalOverlayController: { _, _ in }, callPeer: { _, _ in }, longTap: { _, _ in }, openCheckoutOrReceipt: { _ in }, openSearch: { }, setupReply: { _ in
        }, canSetupReply: { _ in
            return .none
        }, navigateToFirstDateMessage: { _, _ in
        }, requestRedeliveryOfFailedMessages: { _ in
        }, addContact: { _ in
        }, rateCall: { _, _, _ in
        }, requestSelectMessagePollOptions: { _, _ in
        }, requestOpenMessagePollResults: { _, _ in
        }, openAppStorePage: {
        }, displayMessageTooltip: { _, _, _, _ in
        }, seekToTimecode: { _, _, _ in
        }, scheduleCurrentMessage: {
        }, sendScheduledMessagesNow: { _ in
        }, editScheduledMessagesTime: { _ in
        }, performTextSelectionAction: { _, _, _ in
        }, displayImportedMessageTooltip: { _ in
        }, displaySwipeToReplyHint: {
        }, dismissReplyMarkupMessage: { _ in
        }, openMessagePollResults: { _, _ in
        }, openPollCreation: { _ in
        }, displayPollSolution: { _, _ in
        }, displayPsa: { _, _ in
        }, displayDiceTooltip: { _ in
        }, animateDiceSuccess: { _, _ in
        }, displayPremiumStickerTooltip: { _, _ in
        }, displayEmojiPackTooltip: { _, _ in
        }, openPeerContextMenu: { _, _, _, _, _ in
        }, openMessageReplies: { _, _, _ in
        }, openReplyThreadOriginalMessage: { _ in
        }, openMessageStats: { _ in
        }, editMessageMedia: { _, _ in
        }, copyText: { _ in
        }, displayUndo: { _ in
        }, isAnimatingMessage: { _ in
            return false
        }, getMessageTransitionNode: {
            return nil
        }, updateChoosingSticker: { _ in
        }, commitEmojiInteraction: { _, _, _, _ in
        }, openLargeEmojiInfo: { _, _, _ in
        }, openJoinLink: { _ in
        }, openWebView: { _, _, _, _ in
        }, activateAdAction: { _ in
        }, openRequestedPeerSelection: { _, _, _ in
        }, requestMessageUpdate: { _, _ in
        }, cancelInteractiveKeyboardGestures: {
        }, dismissTextInput: {
        }, scrollToMessageId: { _ in
        }, automaticMediaDownloadSettings: MediaAutoDownloadSettings.defaultSettings,
        pollActionState: ChatInterfacePollActionState(), stickerSettings: ChatInterfaceStickerSettings(), presentationContext: ChatPresentationContext(context: context, backgroundNode: backgroundNode as? WallpaperBackgroundNode))
        
        var entryAttributes = ChatMessageEntryAttributes()
        entryAttributes.isCentered = isCentered
        
        let content: ChatMessageItemContent
        let chatLocation: ChatLocation
        if messages.count > 1 {
            content = .group(messages: messages.map { ($0, true, .none, entryAttributes, nil) })
            chatLocation = .peer(id: messages.first!.id.peerId)
        } else {
            content = .message(message: messages.first!, read: true, selection: .none, attributes: entryAttributes, location: nil)
            chatLocation = .peer(id: messages.first!.id.peerId)
        }
        
        return ChatMessageItem(presentationData: ChatPresentationData(theme: ChatPresentationThemeData(theme: theme, wallpaper: wallpaper), fontSize: fontSize, strings: strings, dateTimeFormat: dateTimeFormat, nameDisplayOrder: nameOrder, disableAnimations: false, largeEmoji: false, chatBubbleCorners: chatBubbleCorners, animatedEmojiScale: 1.0, isPreview: true), context: context, chatLocation: chatLocation, associatedData: ChatMessageItemAssociatedData(automaticDownloadPeerType: .contact, automaticDownloadPeerId: nil, automaticDownloadNetworkType: .cellular, isRecentActions: false, subject: nil, contactsPeerIds: Set(), animatedEmojiStickers: [:], forcedResourceStatus: forcedResourceStatus, availableReactions: availableReactions, defaultReaction: nil, isPremium: false, accountPeer: nil, forceInlineReactions: true), controllerInteraction: controllerInteraction, content: content, disableDate: true, additionalContent: nil)
    }
    
    public func makeChatMessageDateHeaderItem(context: AccountContext, timestamp: Int32, theme: PresentationTheme, strings: PresentationStrings, wallpaper: TelegramWallpaper, fontSize: PresentationFontSize, chatBubbleCorners: PresentationChatBubbleCorners, dateTimeFormat: PresentationDateTimeFormat, nameOrder: PresentationPersonNameOrder) -> ListViewItemHeader {
        return ChatMessageDateHeader(timestamp: timestamp, scheduled: false, presentationData: ChatPresentationData(theme: ChatPresentationThemeData(theme: theme, wallpaper: wallpaper), fontSize: fontSize, strings: strings, dateTimeFormat: dateTimeFormat, nameDisplayOrder: nameOrder, disableAnimations: false, largeEmoji: false, chatBubbleCorners: chatBubbleCorners, animatedEmojiScale: 1.0, isPreview: true), controllerInteraction: nil, context: context)
    }
    
    public func openImagePicker(context: AccountContext, completion: @escaping (UIImage) -> Void, present: @escaping (ViewController) -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let _ = legacyWallpaperPicker(context: context, presentationData: presentationData).start(next: { generator in
            let legacyController = LegacyController(presentation: .navigation, theme: presentationData.theme)
            legacyController.navigationPresentation = .modal
            legacyController.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
            
            let controller = generator(legacyController.context)
            legacyController.bind(controller: controller)
            legacyController.deferScreenEdgeGestures = [.top]
            controller.selectionBlock = { [weak legacyController] asset, _ in
                if let asset = asset {
                    let _ = (fetchPhotoLibraryImage(localIdentifier: asset.backingAsset.localIdentifier, thumbnail: false)
                    |> deliverOnMainQueue).start(next: { imageAndFlag in
                        if let (image, _) = imageAndFlag {
                            completion(image)
                        }
                    })
                    if let legacyController = legacyController {
                        legacyController.dismiss()
                    }
                }
            }
            controller.dismissalBlock = { [weak legacyController] in
                if let legacyController = legacyController {
                    legacyController.dismiss()
                }
            }
            present(legacyController)
        })
    }
    
    public func makeRecentSessionsController(context: AccountContext, activeSessionsContext: ActiveSessionsContext) -> ViewController & RecentSessionsController {
        return recentSessionsController(context: context, activeSessionsContext: activeSessionsContext, webSessionsContext: context.engine.privacy.webSessions(), websitesOnly: false)
    }
    
    public func makeChatQrCodeScreen(context: AccountContext, peer: Peer, threadId: Int64?) -> ViewController {
        return ChatQrCodeScreen(context: context, subject: .peer(peer: peer, threadId: threadId, temporary: false))
    }
    
    public func makePrivacyAndSecurityController(context: AccountContext) -> ViewController {
        return SettingsUI.makePrivacyAndSecurityController(context: context)
    }
    
    public func makeSetupTwoFactorAuthController(context: AccountContext) -> ViewController {
        return SettingsUI.makeSetupTwoFactorAuthController(context: context)
    }
    
    public func makeStorageManagementController(context: AccountContext) -> ViewController {
        return StorageUsageScreen(context: context, makeStorageUsageExceptionsScreen: { [weak context] category in
            guard let context else {
                return nil
            }
            return storageUsageExceptionsScreen(context: context, category: category)
        })
    }
    
    public func makeAttachmentFileController(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)?, bannedSendMedia: (Int32, Bool)?, presentGallery: @escaping () -> Void, presentFiles: @escaping () -> Void, send: @escaping (AnyMediaReference) -> Void) -> AttachmentFileController {
        return makeAttachmentFileControllerImpl(context: context, updatedPresentationData: updatedPresentationData, bannedSendMedia: bannedSendMedia, presentGallery: presentGallery, presentFiles: presentFiles, send: send)
    }
    
    public func makeGalleryCaptionPanelView(context: AccountContext, chatLocation: ChatLocation, customEmojiAvailable: Bool, present: @escaping (ViewController) -> Void, presentInGlobalOverlay: @escaping (ViewController) -> Void) -> NSObject? {
        var presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentationData = presentationData.withUpdated(theme: defaultDarkColorPresentationTheme)
        
        var presentationInterfaceState = ChatPresentationInterfaceState(chatWallpaper: .builtin(WallpaperSettings()), theme: presentationData.theme, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, limitsConfiguration: context.currentLimitsConfiguration.with { $0 }, fontSize: presentationData.chatFontSize, bubbleCorners: presentationData.chatBubbleCorners, accountPeerId: context.account.peerId, mode: .standard(previewing: false), chatLocation: chatLocation, subject: nil, peerNearbyData: nil, greetingData: nil, pendingUnpinnedAllMessages: false, activeGroupCallInfo: nil, hasActiveGroupCall: false, importState: nil, threadData: nil, isGeneralThreadClosed: nil)
        
        var updateChatPresentationInterfaceStateImpl: (((ChatPresentationInterfaceState) -> ChatPresentationInterfaceState) -> Void)?
        var ensureFocusedImpl: (() -> Void)?
        
        let interfaceInteraction = ChatPanelInterfaceInteraction(updateTextInputStateAndMode: { f in
            updateChatPresentationInterfaceStateImpl?({
                let (updatedState, updatedMode) = f($0.interfaceState.effectiveInputState, $0.inputMode)
                return $0.updatedInterfaceState { interfaceState in
                    return interfaceState.withUpdatedEffectiveInputState(updatedState)
                }.updatedInputMode({ _ in updatedMode })
            })
        }, updateInputModeAndDismissedButtonKeyboardMessageId: { f in
            updateChatPresentationInterfaceStateImpl?({
                let (updatedInputMode, updatedClosedButtonKeyboardMessageId) = f($0)
                return $0.updatedInputMode({ _ in return updatedInputMode }).updatedInterfaceState({
                    $0.withUpdatedMessageActionsState({ value in
                        var value = value
                        value.closedButtonKeyboardMessageId = updatedClosedButtonKeyboardMessageId
                        return value
                    })
                })
            })
        }, openLinkEditing: {
            var selectionRange: Range<Int>?
            var text: NSAttributedString?
            var inputMode: ChatInputMode?
            updateChatPresentationInterfaceStateImpl?({ state in
                selectionRange = state.interfaceState.effectiveInputState.selectionRange
                if let selectionRange = selectionRange {
                    text = state.interfaceState.effectiveInputState.inputText.attributedSubstring(from: NSRange(location: selectionRange.startIndex, length: selectionRange.count))
                }
                inputMode = state.inputMode
                return state
            })
            
            var link: String?
            if let text {
                text.enumerateAttributes(in: NSMakeRange(0, text.length)) { attributes, _, _ in
                    if let linkAttribute = attributes[ChatTextInputAttributes.textUrl] as? ChatTextInputTextUrlAttribute {
                        link = linkAttribute.url
                    }
                }
            }
            
            let controller = chatTextLinkEditController(sharedContext: context.sharedContext, updatedPresentationData: (presentationData, .never()), account: context.account, text: text?.string ?? "", link: link, apply: { link in
                if let inputMode = inputMode, let selectionRange = selectionRange {
                    if let link = link {
                        updateChatPresentationInterfaceStateImpl?({
                            return $0.updatedInterfaceState({
                                $0.withUpdatedEffectiveInputState(chatTextInputAddLinkAttribute($0.effectiveInputState, selectionRange: selectionRange, url: link))
                            })
                        })
                    }
                    ensureFocusedImpl?()
                    updateChatPresentationInterfaceStateImpl?({
                        return $0.updatedInputMode({ _ in return inputMode }).updatedInterfaceState({
                            $0.withUpdatedEffectiveInputState(ChatTextInputState(inputText: $0.effectiveInputState.inputText, selectionRange: selectionRange.endIndex ..< selectionRange.endIndex))
                        })
                    })
                }
            })
            present(controller)
        })
        
        let inputPanelNode = AttachmentTextInputPanelNode(context: context, presentationInterfaceState: presentationInterfaceState, isCaption: true, presentController: { c in
            presentInGlobalOverlay(c)
        }, makeEntityInputView: {
            return EntityInputView(context: context, isDark: true, areCustomEmojiEnabled: customEmojiAvailable)
        })
        inputPanelNode.interfaceInteraction = interfaceInteraction
        inputPanelNode.effectivePresentationInterfaceState = {
            return presentationInterfaceState
        }
        
        updateChatPresentationInterfaceStateImpl = { [weak inputPanelNode] f in
            let updatedPresentationInterfaceState = f(presentationInterfaceState)
            let updateInputTextState = presentationInterfaceState.interfaceState.effectiveInputState != updatedPresentationInterfaceState.interfaceState.effectiveInputState
            
            presentationInterfaceState = updatedPresentationInterfaceState
            
            if let inputPanelNode = inputPanelNode, updateInputTextState {
                inputPanelNode.updateInputTextState(updatedPresentationInterfaceState.interfaceState.effectiveInputState, animated: true)
            }
        }
        
        ensureFocusedImpl =  { [weak inputPanelNode] in
            inputPanelNode?.ensureFocused()
        }
        
        return inputPanelNode
    }
    
    public func makePremiumIntroController(context: AccountContext, source: PremiumIntroSource) -> ViewController {
        let mappedSource: PremiumSource
        switch source {
        case .settings:
            mappedSource = .settings
        case .stickers:
            mappedSource = .stickers
        case .reactions:
            mappedSource = .reactions
        case .ads:
            mappedSource = .ads
        case .upload:
            mappedSource = .upload
        case .groupsAndChannels:
            mappedSource = .groupsAndChannels
        case .pinnedChats:
            mappedSource = .pinnedChats
        case .publicLinks:
            mappedSource = .publicLinks
        case .savedGifs:
            mappedSource = .savedGifs
        case .savedStickers:
            mappedSource = .savedStickers
        case .folders:
            mappedSource = .folders
        case .chatsPerFolder:
            mappedSource = .chatsPerFolder
        case .appIcons:
            mappedSource = .appIcons
        case .accounts:
            mappedSource = .accounts
        case .about:
            mappedSource = .about
        case let .deeplink(reference):
            mappedSource = .deeplink(reference)
        case let .profile(peerId):
            mappedSource = .profile(peerId)
        case let .emojiStatus(peerId, fileId, file, packTitle):
            mappedSource = .emojiStatus(peerId, fileId, file, packTitle)
        case .voiceToText:
            mappedSource = .voiceToText
        case .fasterDownload:
            mappedSource = .fasterDownload
        case .translation:
            mappedSource = .translation
        }
        return PremiumIntroScreen(context: context, source: mappedSource)
    }
    
    public func makePremiumDemoController(context: AccountContext, subject: PremiumDemoSubject, action: @escaping () -> Void) -> ViewController {
        let mappedSubject: PremiumDemoScreen.Subject
        switch subject {
        case .doubleLimits:
            mappedSubject = .doubleLimits
        case .moreUpload:
            mappedSubject = .moreUpload
        case .fasterDownload:
            mappedSubject = .fasterDownload
        case .voiceToText:
            mappedSubject = .voiceToText
        case .noAds:
            mappedSubject = .noAds
        case .uniqueReactions:
            mappedSubject = .uniqueReactions
        case .premiumStickers:
            mappedSubject = .premiumStickers
        case .advancedChatManagement:
            mappedSubject = .advancedChatManagement
        case .profileBadge:
            mappedSubject = .profileBadge
        case .animatedUserpics:
            mappedSubject = .animatedUserpics
        case .appIcons:
            mappedSubject = .appIcons
        case .animatedEmoji:
            mappedSubject = .animatedEmoji
        case .emojiStatus:
            mappedSubject = .emojiStatus
        case .translation:
            mappedSubject = .translation
        }
        return PremiumDemoScreen(context: context, subject: mappedSubject, action: action)
    }
    
    public func makePremiumLimitController(context: AccountContext, subject: PremiumLimitSubject, count: Int32, action: @escaping () -> Void) -> ViewController {
        let mappedSubject: PremiumLimitScreen.Subject
        switch subject {
        case .folders:
            mappedSubject = .folders
        case .chatsPerFolder:
            mappedSubject =  .chatsPerFolder
        case .pins:
            mappedSubject =  .pins
        case .files:
            mappedSubject =  .files
        case .accounts:
            mappedSubject =  .accounts
        case .linksPerSharedFolder:
            mappedSubject = .linksPerSharedFolder
        case .membershipInSharedFolders:
            mappedSubject = .membershipInSharedFolders
        case .channels:
            mappedSubject = .channels
        }
        return PremiumLimitScreen(context: context, subject: mappedSubject, count: count, action: action)
    }
    
    public func makeStickerPackScreen(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)?, mainStickerPack: StickerPackReference, stickerPacks: [StickerPackReference], loadedStickerPacks: [LoadedStickerPack], parentNavigationController: NavigationController?, sendSticker: ((FileMediaReference, UIView, CGRect) -> Bool)?) -> ViewController {
        return StickerPackScreen(context: context, updatedPresentationData: updatedPresentationData, mainStickerPack: mainStickerPack, stickerPacks: stickerPacks, loadedStickerPacks: loadedStickerPacks, parentNavigationController: parentNavigationController, sendSticker: sendSticker)
    }
        
    public func makeProxySettingsController(sharedContext: SharedAccountContext, account: UnauthorizedAccount) -> ViewController {
        return proxySettingsController(accountManager: sharedContext.accountManager, postbox: account.postbox, network: account.network, mode: .modal, presentationData: sharedContext.currentPresentationData.with { $0 }, updatedPresentationData: sharedContext.presentationData)
    }
    
    public func makeInstalledStickerPacksController(context: AccountContext, mode: InstalledStickerPacksControllerMode) -> ViewController {
        return installedStickerPacksController(context: context, mode: mode)
    }
}

private func peerInfoControllerImpl(context: AccountContext, updatedPresentationData: (PresentationData, Signal<PresentationData, NoError>)?, peer: Peer, mode: PeerInfoControllerMode, avatarInitiallyExpanded: Bool, isOpenedFromChat: Bool, requestsContext: PeerInvitationImportersContext? = nil) -> ViewController? {
    if let _ = peer as? TelegramGroup {
        return PeerInfoScreenImpl(context: context, updatedPresentationData: updatedPresentationData, peerId: peer.id, avatarInitiallyExpanded: avatarInitiallyExpanded, isOpenedFromChat: isOpenedFromChat, nearbyPeerDistance: nil, reactionSourceMessageId: nil, callMessages: [])
    } else if let _ = peer as? TelegramChannel {
        var forumTopicThread: ChatReplyThreadMessage?
        switch mode {
        case let .forumTopic(thread):
            forumTopicThread = thread
        default:
            break
        }
        return PeerInfoScreenImpl(context: context, updatedPresentationData: updatedPresentationData, peerId: peer.id, avatarInitiallyExpanded: avatarInitiallyExpanded, isOpenedFromChat: isOpenedFromChat, nearbyPeerDistance: nil, reactionSourceMessageId: nil, callMessages: [], forumTopicThread: forumTopicThread)
    } else if peer is TelegramUser {
        var nearbyPeerDistance: Int32?
        var reactionSourceMessageId: MessageId?
        var callMessages: [Message] = []
        var hintGroupInCommon: PeerId?
        switch mode {
        case let .nearbyPeer(distance):
            nearbyPeerDistance = distance
        case let .calls(messages):
            callMessages = messages
        case .generic:
            break
        case let .group(id):
            hintGroupInCommon = id
        case let .reaction(messageId):
            reactionSourceMessageId = messageId
        case .forumTopic:
            break
        }
        return PeerInfoScreenImpl(context: context, updatedPresentationData: updatedPresentationData, peerId: peer.id, avatarInitiallyExpanded: avatarInitiallyExpanded, isOpenedFromChat: isOpenedFromChat, nearbyPeerDistance: nearbyPeerDistance, reactionSourceMessageId: reactionSourceMessageId, callMessages: callMessages, hintGroupInCommon: hintGroupInCommon)
    } else if peer is TelegramSecretChat {
        return PeerInfoScreenImpl(context: context, updatedPresentationData: updatedPresentationData, peerId: peer.id, avatarInitiallyExpanded: avatarInitiallyExpanded, isOpenedFromChat: isOpenedFromChat, nearbyPeerDistance: nil, reactionSourceMessageId: nil, callMessages: [])
    }
    return nil
}
