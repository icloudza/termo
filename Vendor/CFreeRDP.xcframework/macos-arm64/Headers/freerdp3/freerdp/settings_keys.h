/**
 * FreeRDP: A Remote Desktop Protocol Implementation
 * Internal settings header for functions not exported
 *
 * Copyright 2023 Armin Novak <armin.novak@thincast.com>
 * Copyright 2023 Thincast Technologies GmbH
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef FREERDP_SETTINGS_KEYS_H
#define FREERDP_SETTINGS_KEYS_H

#include <freerdp/api.h>

#ifdef __cplusplus
extern "C"
{
#endif

/** A list of available settings keys of type BOOL
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_ServerMode = 16,
	FreeRDP_WaitForOutputBufferFlush = 25,
	FreeRDP_NetworkAutoDetect = 137,
	FreeRDP_SupportAsymetricKeys = 138,
	FreeRDP_SupportErrorInfoPdu = 139,
	FreeRDP_SupportStatusInfoPdu = 140,
	FreeRDP_SupportMonitorLayoutPdu = 141,
	FreeRDP_SupportGraphicsPipeline = 142,
	FreeRDP_SupportDynamicTimeZone = 143,
	FreeRDP_SupportHeartbeatPdu = 144,
	FreeRDP_SupportEdgeActionV1 = 150,
	FreeRDP_SupportEdgeActionV2 = 151,
	FreeRDP_SupportSkipChannelJoin = 152,
	FreeRDP_UseRdpSecurityLayer = 192,
	FreeRDP_ServerLicenseRequired = 202,
	FreeRDP_ConsoleSession = 322,
	FreeRDP_SpanMonitors = 387,
	FreeRDP_UseMultimon = 388,
	FreeRDP_ForceMultimon = 389,
	FreeRDP_ListMonitors = 392,
	FreeRDP_HasMonitorAttributes = 397,
	FreeRDP_SupportMultitransport = 513,
	FreeRDP_AutoLogonEnabled = 704,
	FreeRDP_CompressionEnabled = 705,
	FreeRDP_DisableCtrlAltDel = 706,
	FreeRDP_EnableWindowsKey = 707,
	FreeRDP_MaximizeShell = 708,
	FreeRDP_LogonNotify = 709,
	FreeRDP_LogonErrors = 710,
	FreeRDP_MouseAttached = 711,
	FreeRDP_MouseHasWheel = 712,
	FreeRDP_RemoteConsoleAudio = 713,
	FreeRDP_AudioPlayback = 714,
	FreeRDP_AudioCapture = 715,
	FreeRDP_VideoDisable = 716,
	FreeRDP_PasswordIsSmartcardPin = 717,
	FreeRDP_UsingSavedCredentials = 718,
	FreeRDP_ForceEncryptedCsPdu = 719,
	FreeRDP_HiDefRemoteApp = 720,
	FreeRDP_IPv6Enabled = 768,
	FreeRDP_AutoReconnectionEnabled = 832,
	FreeRDP_PrintReconnectCookie = 836,
	FreeRDP_AutoReconnectionPacketSupported = 837,
	FreeRDP_DynamicDaylightTimeDisabled = 898,
	FreeRDP_AllowFontSmoothing = 961,
	FreeRDP_DisableWallpaper = 962,
	FreeRDP_DisableFullWindowDrag = 963,
	FreeRDP_DisableMenuAnims = 964,
	FreeRDP_DisableThemes = 965,
	FreeRDP_DisableCursorShadow = 966,
	FreeRDP_DisableCursorBlinking = 967,
	FreeRDP_AllowDesktopComposition = 968,
	FreeRDP_RemoteAssistanceMode = 1024,
	FreeRDP_EncomspVirtualChannel = 1029,
	FreeRDP_RemdeskVirtualChannel = 1030,
	FreeRDP_LyncRdpMode = 1031,
	FreeRDP_RemoteAssistanceRequestControl = 1032,
	FreeRDP_TlsSecurity = 1088,
	FreeRDP_NlaSecurity = 1089,
	FreeRDP_RdpSecurity = 1090,
	FreeRDP_ExtSecurity = 1091,
	FreeRDP_Authentication = 1092,
	FreeRDP_NegotiateSecurityLayer = 1096,
	FreeRDP_RestrictedAdminModeRequired = 1097,
	FreeRDP_DisableCredentialsDelegation = 1099,
	FreeRDP_VmConnectMode = 1102,
	FreeRDP_FIPSMode = 1104,
	FreeRDP_RdstlsSecurity = 1111,
	FreeRDP_AadSecurity = 1112,
	FreeRDP_RemoteCredentialGuard = 1114,
	FreeRDP_MstscCookieMode = 1152,
	FreeRDP_SendPreconnectionPdu = 1156,
	FreeRDP_SmartcardLogon = 1282,
	FreeRDP_PromptForCredentials = 1283,
	FreeRDP_SmartcardEmulation = 1288,
	FreeRDP_KerberosRdgIsProxy = 1352,
	FreeRDP_IgnoreCertificate = 1408,
	FreeRDP_ExternalCertificateManagement = 1415,
	FreeRDP_AutoAcceptCertificate = 1419,
	FreeRDP_AutoDenyCertificate = 1420,
	FreeRDP_CertificateCallbackPreferPEM = 1423,
	FreeRDP_Workarea = 1536,
	FreeRDP_Fullscreen = 1537,
	FreeRDP_GrabKeyboard = 1539,
	FreeRDP_Decorations = 1540,
	FreeRDP_MouseMotion = 1541,
	FreeRDP_AsyncUpdate = 1545,
	FreeRDP_AsyncChannels = 1546,
	FreeRDP_ToggleFullscreen = 1548,
	FreeRDP_EmbeddedWindow = 1550,
	FreeRDP_SmartSizing = 1551,
	FreeRDP_PercentScreenUseWidth = 1556,
	FreeRDP_PercentScreenUseHeight = 1557,
	FreeRDP_DynamicResolutionUpdate = 1558,
	FreeRDP_GrabMouse = 1559,
	FreeRDP_SoftwareGdi = 1601,
	FreeRDP_LocalConnection = 1602,
	FreeRDP_AuthenticationOnly = 1603,
	FreeRDP_CredentialsFromStdin = 1604,
	FreeRDP_UnmapButtons = 1605,
	FreeRDP_OldLicenseBehaviour = 1606,
	FreeRDP_MouseUseRelativeMove = 1607,
	FreeRDP_UseCommonStdioCallbacks = 1608,
	FreeRDP_ConnectChildSession = 1609,
	FreeRDP_DumpRemoteFx = 1856,
	FreeRDP_PlayRemoteFx = 1857,
	FreeRDP_TransportDump = 1860,
	FreeRDP_TransportDumpReplay = 1862,
	FreeRDP_DeactivateClientDecoding = 1863,
	FreeRDP_TransportDumpReplayNodelay = 1864,
	FreeRDP_GatewayUseSameCredentials = 1991,
	FreeRDP_GatewayEnabled = 1992,
	FreeRDP_GatewayBypassLocal = 1993,
	FreeRDP_GatewayRpcTransport = 1994,
	FreeRDP_GatewayHttpTransport = 1995,
	FreeRDP_GatewayUdpTransport = 1996,
	FreeRDP_GatewayHttpUseWebsockets = 2000,
	FreeRDP_GatewayHttpExtAuthSspiNtlm = 2001,
	FreeRDP_GatewayArmTransport = 2004,
	FreeRDP_GatewayIgnoreRedirectionPolicy = 2012,
	FreeRDP_RemoteApplicationMode = 2112,
	FreeRDP_DisableRemoteAppCapsCheck = 2121,
	FreeRDP_RemoteAppLanguageBarSupported = 2124,
	FreeRDP_RefreshRect = 2306,
	FreeRDP_SuppressOutput = 2307,
	FreeRDP_FastPathOutput = 2308,
	FreeRDP_SaltedChecksum = 2309,
	FreeRDP_LongCredentialsSupported = 2310,
	FreeRDP_NoBitmapCompressionHeader = 2311,
	FreeRDP_BitmapCompressionDisabled = 2312,
	FreeRDP_DesktopResize = 2368,
	FreeRDP_DrawAllowDynamicColorFidelity = 2369,
	FreeRDP_DrawAllowColorSubsampling = 2370,
	FreeRDP_DrawAllowSkipAlpha = 2371,
	FreeRDP_BitmapCacheV3Enabled = 2433,
	FreeRDP_AltSecFrameMarkerSupport = 2434,
	FreeRDP_AllowUnanouncedOrdersFromServer = 2435,
	FreeRDP_BitmapCacheEnabled = 2497,
	FreeRDP_AllowCacheWaitingList = 2499,
	FreeRDP_BitmapCachePersistEnabled = 2500,
	FreeRDP_UnicodeInput = 2629,
	FreeRDP_FastPathInput = 2630,
	FreeRDP_MultiTouchInput = 2631,
	FreeRDP_MultiTouchGestures = 2632,
	FreeRDP_HasHorizontalWheel = 2634,
	FreeRDP_HasExtendedMouseEvent = 2635,
	FreeRDP_SuspendInput = 2636,
	FreeRDP_HasRelativeMouseEvent = 2638,
	FreeRDP_HasQoeEvent = 2639,
	FreeRDP_SoundBeepsEnabled = 2944,
	FreeRDP_SurfaceCommandsEnabled = 3520,
	FreeRDP_FrameMarkerCommandEnabled = 3521,
	FreeRDP_SurfaceFrameMarkerEnabled = 3522,
	FreeRDP_RemoteFxOnly = 3648,
	FreeRDP_RemoteFxCodec = 3649,
	FreeRDP_RemoteFxImageCodec = 3652,
	FreeRDP_NSCodec = 3712,
	FreeRDP_NSCodecAllowSubsampling = 3716,
	FreeRDP_NSCodecAllowDynamicColorFidelity = 3717,
	FreeRDP_JpegCodec = 3776,
	FreeRDP_GfxThinClient = 3840,
	FreeRDP_GfxSmallCache = 3841,
	FreeRDP_GfxProgressive = 3842,
	FreeRDP_GfxProgressiveV2 = 3843,
	FreeRDP_GfxH264 = 3844,
	FreeRDP_GfxAVC444 = 3845,
	FreeRDP_GfxSendQoeAck = 3846,
	FreeRDP_GfxAVC444v2 = 3847,
	FreeRDP_GfxPlanar = 3849,
	FreeRDP_GfxSuspendFrameAck = 3850,
	FreeRDP_DrawNineGridEnabled = 3968,
	FreeRDP_DrawGdiPlusEnabled = 4032,
	FreeRDP_DrawGdiPlusCacheEnabled = 4033,
	FreeRDP_DeviceRedirection = 4160,
	FreeRDP_IgnoreInvalidDevices = 4164,
	FreeRDP_RedirectDrives = 4288,
	FreeRDP_RedirectHomeDrive = 4289,
	FreeRDP_RedirectSmartCards = 4416,
	FreeRDP_RedirectWebAuthN = 4417,
	FreeRDP_RedirectPrinters = 4544,
	FreeRDP_RedirectSerialPorts = 4672,
	FreeRDP_RedirectParallelPorts = 4673,
	FreeRDP_PreferIPv6OverIPv4 = 4674,
	FreeRDP_RedirectClipboard = 4800,
	FreeRDP_SynchronousStaticChannels = 4931,
	FreeRDP_SupportDynamicChannels = 5059,
	FreeRDP_SynchronousDynamicChannels = 5060,
	FreeRDP_SupportEchoChannel = 5184,
	FreeRDP_SupportDisplayControl = 5185,
	FreeRDP_SupportGeometryTracking = 5186,
	FreeRDP_SupportSSHAgentChannel = 5187,
	FreeRDP_SupportVideoOptimized = 5188,
	FreeRDP_TcpKeepAlive = 5190,
	FreeRDP_BOOL_UNUSED = -1
} FreeRDP_Settings_Keys_Bool;

/** A list of available settings keys of type INT16
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_INT16_UNUSED = -1
} FreeRDP_Settings_Keys_Int16;

/** A list of available settings keys of type UINT16
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_DesktopOrientation = 147,
	FreeRDP_SupportedColorDepths = 153,
	FreeRDP_TLSMinVersion = 1107,
	FreeRDP_TLSMaxVersion = 1108,
	FreeRDP_ProxyPort = 2017,
	FreeRDP_CapsProtocolVersion = 2313,
	FreeRDP_CapsGeneralCompressionTypes = 2314,
	FreeRDP_CapsUpdateCapabilityFlag = 2315,
	FreeRDP_CapsRemoteUnshareFlag = 2316,
	FreeRDP_CapsGeneralCompressionLevel = 2317,
	FreeRDP_OrderSupportFlags = 2436,
	FreeRDP_OrderSupportFlagsEx = 2437,
	FreeRDP_TextANSICodePage = 2439,
	FreeRDP_UINT16_UNUSED = -1
} FreeRDP_Settings_Keys_UInt16;

/** A list of available settings keys of type INT32
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_XPan = 1552,
	FreeRDP_YPan = 1553,
	FreeRDP_INT32_UNUSED = -1
} FreeRDP_Settings_Keys_Int32;

/** A list of available settings keys of type UINT32
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_ShareId = 17,
	FreeRDP_PduSource = 18,
	FreeRDP_ServerPort = 19,
	FreeRDP_AcceptedCertLength = 28,
	FreeRDP_ThreadingFlags = 64,
	FreeRDP_RdpVersion = 128,
	FreeRDP_DesktopWidth = 129,
	FreeRDP_DesktopHeight = 130,
	FreeRDP_ColorDepth = 131,
	FreeRDP_ConnectionType = 132,
	FreeRDP_ClientBuild = 133,
	FreeRDP_EarlyCapabilityFlags = 136,
	FreeRDP_DesktopPhysicalWidth = 145,
	FreeRDP_DesktopPhysicalHeight = 146,
	FreeRDP_DesktopScaleFactor = 148,
	FreeRDP_DeviceScaleFactor = 149,
	FreeRDP_EncryptionMethods = 193,
	FreeRDP_ExtEncryptionMethods = 194,
	FreeRDP_EncryptionLevel = 195,
	FreeRDP_ServerRandomLength = 197,
	FreeRDP_ServerCertificateLength = 199,
	FreeRDP_ClientRandomLength = 201,
	FreeRDP_ServerLicenseProductVersion = 204,
	FreeRDP_ServerLicenseProductIssuersCount = 207,
	FreeRDP_ChannelCount = 256,
	FreeRDP_ChannelDefArraySize = 257,
	FreeRDP_ClusterInfoFlags = 320,
	FreeRDP_RedirectedSessionId = 321,
	FreeRDP_MonitorCount = 384,
	FreeRDP_MonitorDefArraySize = 385,
	FreeRDP_DesktopPosX = 390,
	FreeRDP_DesktopPosY = 391,
	FreeRDP_NumMonitorIds = 394,
	FreeRDP_MonitorLocalShiftX = 395,
	FreeRDP_MonitorLocalShiftY = 396,
	FreeRDP_MonitorFlags = 398,
	FreeRDP_MonitorAttributeFlags = 399,
	FreeRDP_MultitransportFlags = 512,
	FreeRDP_CompressionLevel = 721,
	FreeRDP_ClientSessionId = 771,
	FreeRDP_AutoReconnectMaxRetries = 833,
	FreeRDP_PerformanceFlags = 960,
	FreeRDP_RequestedProtocols = 1093,
	FreeRDP_SelectedProtocol = 1094,
	FreeRDP_NegotiationFlags = 1095,
	FreeRDP_AuthenticationLevel = 1100,
	FreeRDP_TlsSecLevel = 1105,
	FreeRDP_CookieMaxLength = 1153,
	FreeRDP_PreconnectionId = 1154,
	FreeRDP_RedirectionFlags = 1216,
	FreeRDP_LoadBalanceInfoLength = 1219,
	FreeRDP_RedirectionPasswordLength = 1223,
	FreeRDP_RedirectionTsvUrlLength = 1227,
	FreeRDP_TargetNetAddressCount = 1228,
	FreeRDP_RedirectionAcceptedCertLength = 1232,
	FreeRDP_RedirectionPreferType = 1233,
	FreeRDP_RedirectionGuidLength = 1235,
	FreeRDP_Password51Length = 1281,
	FreeRDP_KeySpec = 1291,
	FreeRDP_PercentScreen = 1538,
	FreeRDP_SmartSizingWidth = 1554,
	FreeRDP_SmartSizingHeight = 1555,
	FreeRDP_GatewayUsageMethod = 1984,
	FreeRDP_GatewayPort = 1985,
	FreeRDP_GatewayCredentialsSource = 1990,
	FreeRDP_GatewayAcceptedCertLength = 1999,
	FreeRDP_ProxyType = 2015,
	FreeRDP_RemoteApplicationExpandCmdLine = 2119,
	FreeRDP_RemoteApplicationExpandWorkingDir = 2120,
	FreeRDP_RemoteAppNumIconCaches = 2122,
	FreeRDP_RemoteAppNumIconCacheEntries = 2123,
	FreeRDP_RemoteWndSupportLevel = 2125,
	FreeRDP_RemoteApplicationSupportLevel = 2126,
	FreeRDP_RemoteApplicationSupportMask = 2127,
	FreeRDP_ReceivedCapabilitiesSize = 2241,
	FreeRDP_OsMajorType = 2304,
	FreeRDP_OsMinorType = 2305,
	FreeRDP_BitmapCacheVersion = 2498,
	FreeRDP_BitmapCacheV2NumCells = 2501,
	FreeRDP_ColorPointerCacheSize = 2560,
	FreeRDP_PointerCacheSize = 2561,
	FreeRDP_KeyboardCodePage = 2623,
	FreeRDP_KeyboardLayout = 2624,
	FreeRDP_KeyboardType = 2625,
	FreeRDP_KeyboardSubType = 2626,
	FreeRDP_KeyboardFunctionKey = 2627,
	FreeRDP_KeyboardHook = 2633,
	FreeRDP_BrushSupportLevel = 2688,
	FreeRDP_GlyphSupportLevel = 2752,
	FreeRDP_OffscreenSupportLevel = 2816,
	FreeRDP_OffscreenCacheSize = 2817,
	FreeRDP_OffscreenCacheEntries = 2818,
	FreeRDP_VCFlags = 2880,
	FreeRDP_VCChunkSize = 2881,
	FreeRDP_MultifragMaxRequestSize = 3328,
	FreeRDP_LargePointerFlag = 3392,
	FreeRDP_CompDeskSupportLevel = 3456,
	FreeRDP_SurfaceCommandsSupported = 3523,
	FreeRDP_RemoteFxCodecId = 3650,
	FreeRDP_RemoteFxCodecMode = 3651,
	FreeRDP_RemoteFxCaptureFlags = 3653,
	FreeRDP_RemoteFxRlgrMode = 3654,
	FreeRDP_NSCodecId = 3713,
	FreeRDP_FrameAcknowledge = 3714,
	FreeRDP_NSCodecColorLossLevel = 3715,
	FreeRDP_JpegCodecId = 3777,
	FreeRDP_JpegQuality = 3778,
	FreeRDP_GfxCapsFilter = 3848,
	FreeRDP_BitmapCacheV3CodecId = 3904,
	FreeRDP_DrawNineGridCacheSize = 3969,
	FreeRDP_DrawNineGridCacheEntries = 3970,
	FreeRDP_DeviceCount = 4161,
	FreeRDP_DeviceArraySize = 4162,
	FreeRDP_ForceIPvX = 4675,
	FreeRDP_ClipboardFeatureMask = 4801,
	FreeRDP_StaticChannelCount = 4928,
	FreeRDP_StaticChannelArraySize = 4929,
	FreeRDP_DynamicChannelCount = 5056,
	FreeRDP_DynamicChannelArraySize = 5057,
	FreeRDP_TcpKeepAliveRetries = 5191,
	FreeRDP_TcpKeepAliveDelay = 5192,
	FreeRDP_TcpKeepAliveInterval = 5193,
	FreeRDP_TcpAckTimeout = 5194,
	FreeRDP_Floatbar = 5196,
	FreeRDP_TcpConnectTimeout = 5197,
	FreeRDP_FakeMouseMotionInterval = 5198,
	FreeRDP_UINT32_UNUSED = -1
} FreeRDP_Settings_Keys_UInt32;

/** A list of available settings keys of type INT64
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_INT64_UNUSED = -1
} FreeRDP_Settings_Keys_Int64;

/** A list of available settings keys of type UINT64
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_ParentWindowId = 1543,
	FreeRDP_UINT64_UNUSED = -1
} FreeRDP_Settings_Keys_UInt64;

/** A list of available settings keys of type STRING
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_ServerHostname = 20,
	FreeRDP_Username = 21,
	FreeRDP_Password = 22,
	FreeRDP_Domain = 23,
	FreeRDP_PasswordHash = 24,
	FreeRDP_AcceptedCert = 27,
	FreeRDP_UserSpecifiedServerName = 29,
	FreeRDP_AadServerHostname = 30,
	FreeRDP_ClientHostname = 134,
	FreeRDP_ClientProductId = 135,
	FreeRDP_ServerLicenseCompanyName = 203,
	FreeRDP_ServerLicenseProductName = 205,
	FreeRDP_AlternateShell = 640,
	FreeRDP_ShellWorkingDirectory = 641,
	FreeRDP_ClientAddress = 769,
	FreeRDP_ClientDir = 770,
	FreeRDP_DynamicDSTTimeZoneKeyName = 897,
	FreeRDP_RemoteAssistanceSessionId = 1025,
	FreeRDP_RemoteAssistancePassStub = 1026,
	FreeRDP_RemoteAssistancePassword = 1027,
	FreeRDP_RemoteAssistanceRCTicket = 1028,
	FreeRDP_AuthenticationServiceClass = 1098,
	FreeRDP_AllowedTlsCiphers = 1101,
	FreeRDP_NtlmSamFile = 1103,
	FreeRDP_SspiModule = 1106,
	FreeRDP_TlsSecretsFile = 1109,
	FreeRDP_AuthenticationPackageList = 1110,
	FreeRDP_WinSCardModule = 1113,
	FreeRDP_PreconnectionBlob = 1155,
	FreeRDP_TargetNetAddress = 1217,
	FreeRDP_RedirectionUsername = 1220,
	FreeRDP_RedirectionDomain = 1221,
	FreeRDP_RedirectionTargetFQDN = 1224,
	FreeRDP_RedirectionTargetNetBiosName = 1225,
	FreeRDP_RedirectionAcceptedCert = 1231,
	FreeRDP_SmartcardCertificate = 1285,
	FreeRDP_SmartcardPrivateKey = 1286,
	FreeRDP_Pkcs11Module = 1289,
	FreeRDP_PkinitAnchors = 1290,
	FreeRDP_CardName = 1292,
	FreeRDP_ReaderName = 1293,
	FreeRDP_ContainerName = 1294,
	FreeRDP_CspName = 1295,
	FreeRDP_KerberosKdcUrl = 1344,
	FreeRDP_KerberosRealm = 1345,
	FreeRDP_KerberosStartTime = 1346,
	FreeRDP_KerberosLifeTime = 1347,
	FreeRDP_KerberosRenewableLifeTime = 1348,
	FreeRDP_KerberosCache = 1349,
	FreeRDP_KerberosArmor = 1350,
	FreeRDP_KerberosKeytab = 1351,
	FreeRDP_CertificateName = 1409,
	FreeRDP_CertificateAcceptedFingerprints = 1421,
	FreeRDP_WindowTitle = 1542,
	FreeRDP_WmClass = 1549,
	FreeRDP_ComputerName = 1664,
	FreeRDP_ConnectionFile = 1728,
	FreeRDP_AssistanceFile = 1729,
	FreeRDP_HomePath = 1792,
	FreeRDP_ConfigPath = 1793,
	FreeRDP_CurrentPath = 1794,
	FreeRDP_DumpRemoteFxFile = 1858,
	FreeRDP_PlayRemoteFxFile = 1859,
	FreeRDP_TransportDumpFile = 1861,
	FreeRDP_GatewayHostname = 1986,
	FreeRDP_GatewayUsername = 1987,
	FreeRDP_GatewayPassword = 1988,
	FreeRDP_GatewayDomain = 1989,
	FreeRDP_GatewayAccessToken = 1997,
	FreeRDP_GatewayAcceptedCert = 1998,
	FreeRDP_GatewayHttpExtAuthBearer = 2002,
	FreeRDP_GatewayUrl = 2003,
	FreeRDP_GatewayAvdWvdEndpointPool = 2005,
	FreeRDP_GatewayAvdGeo = 2006,
	FreeRDP_GatewayAvdArmpath = 2007,
	FreeRDP_GatewayAvdAadtenantid = 2008,
	FreeRDP_GatewayAvdDiagnosticserviceurl = 2009,
	FreeRDP_GatewayAvdHubdiscoverygeourl = 2010,
	FreeRDP_GatewayAvdActivityhint = 2011,
	FreeRDP_ProxyHostname = 2016,
	FreeRDP_ProxyUsername = 2018,
	FreeRDP_ProxyPassword = 2019,
	FreeRDP_RemoteApplicationName = 2113,
	FreeRDP_RemoteApplicationIcon = 2114,
	FreeRDP_RemoteApplicationProgram = 2115,
	FreeRDP_RemoteApplicationFile = 2116,
	FreeRDP_RemoteApplicationGuid = 2117,
	FreeRDP_RemoteApplicationCmdLine = 2118,
	FreeRDP_RemoteApplicationWorkingDir = 2128,
	FreeRDP_TerminalDescriptor = 2438,
	FreeRDP_BitmapCachePersistFile = 2503,
	FreeRDP_KeyboardRemappingList = 2622,
	FreeRDP_ImeFileName = 2628,
	FreeRDP_KeyboardPipeName = 2637,
	FreeRDP_DrivesToRedirect = 4290,
	FreeRDP_ClipboardUseSelection = 4802,
	FreeRDP_RDP2TCPArgs = 5189,
	FreeRDP_ActionScript = 5195,
	FreeRDP_STRING_UNUSED = -1
} FreeRDP_Settings_Keys_String;

/** A list of available settings keys of type POINTER
 *
 *  \since version 3.0.0
 */
typedef enum
{
    FreeRDP_instance = 0,
	FreeRDP_ServerRandom = 196,
	FreeRDP_ServerCertificate = 198,
	FreeRDP_ClientRandom = 200,
	FreeRDP_ServerLicenseProductIssuers = 206,
	FreeRDP_ChannelDefArray = 258,
	FreeRDP_MonitorDefArray = 386,
	FreeRDP_MonitorIds = 393,
	FreeRDP_ClientAutoReconnectCookie = 834,
	FreeRDP_ServerAutoReconnectCookie = 835,
	FreeRDP_ClientTimeZone = 896,
	FreeRDP_LoadBalanceInfo = 1218,
	FreeRDP_RedirectionPassword = 1222,
	FreeRDP_RedirectionTsvUrl = 1226,
	FreeRDP_TargetNetAddresses = 1229,
	FreeRDP_TargetNetPorts = 1230,
	FreeRDP_RedirectionGuid = 1234,
	FreeRDP_RedirectionTargetCertificate = 1236,
	FreeRDP_Password51 = 1280,
	FreeRDP_RdpServerRsaKey = 1413,
	FreeRDP_RdpServerCertificate = 1414,
	FreeRDP_ReceivedCapabilities = 2240,
	FreeRDP_ReceivedCapabilityData = 2242,
	FreeRDP_ReceivedCapabilityDataSizes = 2243,
	FreeRDP_OrderSupport = 2432,
	FreeRDP_BitmapCacheV2CellInfo = 2502,
	FreeRDP_GlyphCache = 2753,
	FreeRDP_FragCache = 2754,
	FreeRDP_DeviceArray = 4163,
	FreeRDP_StaticChannelArray = 4930,
	FreeRDP_DynamicChannelArray = 5058,
	FreeRDP_POINTER_UNUSED = -1
} FreeRDP_Settings_Keys_Pointer;


/** Highest indes in the rdpSettings stable API
 *
 *  \since version 3.0.0
 */
#define FreeRDP_Settings_StableAPI_MAX 5312

#ifdef __cplusplus
}
#endif

#endif /* FREERDP_SETTINGS_KEYS_H */
