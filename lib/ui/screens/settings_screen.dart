import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/storage/secure_storage_service.dart';
import '../../core/storage/directory_service.dart';
import '../../core/storage/system_utils.dart';
import '../../providers/romm_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/shared_prefs_provider.dart';
import '../../providers/downloaded_games_cache_provider.dart';
import '../../providers/ui_provider.dart';
import '../../providers/retroachievements_provider.dart';
import '../../core/input/controller_keymap.dart';
import '../../core/romm/romm_service.dart';
import '../../core/romm/romm_models.dart';
import '../../core/storage/logger_service.dart';
import 'settings_display_section.dart';
import '../library_focus_bridge.dart';
import '../../core/constants/app_constants.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  /// When true (nested under library shell), hides AppBar and B pops the shell route.
  final bool embeddedShell;

  /// Xbox / keyboard focus scope for the embedded shell body ([embeddedShell] only).
  final FocusNode? shellFocusNode;

  const SettingsScreen({super.key, this.embeddedShell = false, this.shellFocusNode});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _baseUrlController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _apiKeyController;
  late TextEditingController _raUsernameController;
  late TextEditingController _raApiKeyController;
  bool _preferencesLoaded = false;
  bool _isLegacyAuth = false;
  bool _isTestingConnection = false;
  bool _isTestingRaConnection = false;
  String? _connectionError;
  String? _pairedToken;
  bool _connectionSuccess = false;
  String? _raConnectionError;
  bool _raConnectionSuccess = false;
  final FocusNode _controllerFocusNode = FocusNode(debugLabel: 'settingsController');

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _apiKeyController = TextEditingController();
    _raUsernameController = TextEditingController();
    _raApiKeyController = TextEditingController();
  }

  @override
  void dispose() {
    _controllerFocusNode.dispose();
    _baseUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    _raUsernameController.dispose();
    _raApiKeyController.dispose();
    super.dispose();
  }

  void _handleControllerNavigation(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final key = event.logicalKey;
    final focusScope = FocusScope.of(context);
    final hasTargetFocus =
        focusScope.focusedChild != null && focusScope.focusedChild != _controllerFocusNode;

    if (ControllerKeyMap.isUp(key)) {
      if (!hasTargetFocus) {
        focusScope.nextFocus();
      } else {
        focusScope.focusInDirection(TraversalDirection.up);
      }
      return;
    }
    if (ControllerKeyMap.isDown(key)) {
      if (!hasTargetFocus) {
        focusScope.nextFocus();
      } else {
        focusScope.focusInDirection(TraversalDirection.down);
      }
      return;
    }
    if (ControllerKeyMap.isLeft(key)) {
      if (!hasTargetFocus) {
        focusScope.nextFocus();
      } else {
        focusScope.focusInDirection(TraversalDirection.left);
      }
      return;
    }
    if (ControllerKeyMap.isRight(key)) {
      if (!hasTargetFocus) {
        focusScope.nextFocus();
      } else {
        focusScope.focusInDirection(TraversalDirection.right);
      }
      return;
    }
    if (ControllerKeyMap.isSelect(key)) {
      if (!hasTargetFocus) {
        focusScope.nextFocus();
      } else {
        Actions.invoke(context, const ActivateIntent());
      }
      return;
    }
    if (ControllerKeyMap.isBack(key)) {
      if (widget.embeddedShell && Navigator.of(context).canPop()) {
        LibraryFocusBridge.popShellHome?.call();
        return;
      }
      ref.read(currentTabIndexProvider.notifier).state = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final directoryServiceAsync = ref.watch(directoryServiceProvider);
    final rommService = ref.watch(rommServiceProvider);
    final rommConfigAsync = ref.watch(rommConfigProvider);

    final cardAspectRatio = ref.watch(cardAspectRatioProvider);
    final columnCount = ref.watch(columnCountProvider);
    final cardSpacing = ref.watch(cardSpacingProvider);
    final showTitle = ref.watch(showTitleProvider);
    final activePreset = ref.watch(activePresetProvider);

    Widget bodyContent = rommConfigAsync.when(
        data: (rommConfig) {
          if (!_preferencesLoaded) {
            final prefs = ref.read(sharedPreferencesProvider);
            _baseUrlController.text = rommConfig.baseUrl;
            _usernameController.text = rommConfig.username;
            _passwordController.text = rommConfig.password;
            _apiKeyController.text = rommConfig.apiKey;
            _raUsernameController.text = prefs.getString('raUsername') ?? '';
            SecureStorageService.read('raApiKey', prefs).then((value) {
              if (!mounted) return;
              _raApiKeyController.text = value ?? '';
            });
            _isLegacyAuth = rommConfig.apiKey.isEmpty && 
                           (rommConfig.username.isNotEmpty || rommConfig.password.isNotEmpty);
            _preferencesLoaded = true;
          }
          return directoryServiceAsync.when(
            data: (directoryService) {
              if (directoryService == null) return const Center(child: Text('Storage service not available.'));

              return ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  _buildRommServerSection(context, ref, rommService, rommConfig),
                  const SizedBox(height: 24),
                  _buildRetroAchievementsSection(context, ref),
                  const SizedBox(height: 24),
                  buildDisplaySection(context, cardAspectRatio, columnCount, cardSpacing, showTitle, activePreset, ref),
                  const SizedBox(height: 24),
                  _buildStorageSection(directoryService),
                  const SizedBox(height: 24),
                  if (defaultTargetPlatform == TargetPlatform.linux) ...[
                    _buildLinuxSettingsSection(context, ref, directoryService),
                    const SizedBox(height: 24),
                  ],
                  _buildLegalSection(context),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, s) => Center(child: Text('Error: $e')),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Error: $e')),
        );

    if (widget.embeddedShell && widget.shellFocusNode != null) {
      bodyContent = Focus(
        focusNode: widget.shellFocusNode,
        child: bodyContent,
      );
    }

    return KeyboardListener(
      focusNode: _controllerFocusNode,
      autofocus: true,
      onKeyEvent: _handleControllerNavigation,
      child: Scaffold(
        appBar: widget.embeddedShell
            ? null
            : AppBar(
                title: Row(
                  children: [
                    Image.asset('freegosy_logo.png', height: 32, width: 32),
                    const SizedBox(width: 12),
                    const Text('Settings'),
                  ],
                ),
              ),
        body: bodyContent,
      ),
    );
  }

  Widget _buildRetroAchievementsSection(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'RetroAchievements',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _raUsernameController,
          decoration: const InputDecoration(
            labelText: 'RetroAchievements Username',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _raApiKeyController,
          decoration: const InputDecoration(
            labelText: 'Web API Key',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
        const SizedBox(height: 16),
        if (_raConnectionError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _raConnectionError!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        if (_raConnectionSuccess)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'RetroAchievements connected!',
              style: TextStyle(color: Colors.green, fontSize: 13),
            ),
          ),
        Row(
          children: [
            ElevatedButton(
              onPressed: _isTestingRaConnection
                  ? null
                  : () async {
                      final username = _raUsernameController.text.trim();
                      final apiKey = _raApiKeyController.text.trim();
                      if (username.isEmpty || apiKey.isEmpty) {
                        setState(() {
                          _raConnectionError = 'Username and API Key are required';
                          _raConnectionSuccess = false;
                        });
                        return;
                      }

                      setState(() {
                        _isTestingRaConnection = true;
                        _raConnectionError = null;
                        _raConnectionSuccess = false;
                      });

                      try {
                        final prefs = ref.read(sharedPreferencesProvider);
                        await prefs.setString('raUsername', username);
                        await SecureStorageService.write('raApiKey', apiKey, prefs);
                        await saveRaCredentialsToFile(
                          RaCredentials(username: username, apiKey: apiKey),
                        );
                        ref.invalidate(raCredentialsProvider);
                        ref.invalidate(raUserProfileProvider);
                        ref.invalidate(raFriendsProvider);
                        ref.invalidate(raRecentGamesProvider);
                        if (!mounted) return;
                        setState(() {
                          _isTestingRaConnection = false;
                          _raConnectionSuccess = true;
                        });
                      } catch (e) {
                        if (!mounted) return;
                        setState(() {
                          _isTestingRaConnection = false;
                          _raConnectionError = 'Could not save credentials: $e';
                        });
                      }
                    },
              child: _isTestingRaConnection
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save / Connect'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () async {
                final prefs = ref.read(sharedPreferencesProvider);
                await prefs.remove('raUsername');
                await SecureStorageService.delete('raApiKey', prefs);
                await deleteRaCredentialsFile();
                ref.invalidate(raCredentialsProvider);
                ref.invalidate(raUserProfileProvider);
                ref.invalidate(raFriendsProvider);
                ref.invalidate(raRecentGamesProvider);
                if (!mounted) return;
                setState(() {
                  _raUsernameController.clear();
                  _raApiKeyController.clear();
                  _raConnectionError = null;
                  _raConnectionSuccess = false;
                });
              },
              child: const Text('Disconnect'),
            ),
          ],
        ),
      ],
    );
  }

  // --- RomM Server Section (Kept as is) ---
  Widget _buildRommServerSection(BuildContext context, WidgetRef ref, RommService? rommService, RomMConfig rommConfig) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('RomM Server', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      TextField(controller: _baseUrlController, decoration: const InputDecoration(labelText: 'Server URL', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      if (_isLegacyAuth) ...[
        TextField(controller: _usernameController, decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: _passwordController, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()), obscureText: true),
      ] else
        TextField(controller: _apiKeyController, decoration: const InputDecoration(labelText: 'API Key (RomM 4.8+)', border: OutlineInputBorder()), obscureText: true),
      const SizedBox(height: 16),
      Row(children: [
        const Text('Legacy Authentication'),
        const Spacer(),
        Switch(value: _isLegacyAuth, onChanged: (val) => setState(() => _isLegacyAuth = val)),
      ]),
      const SizedBox(height: 16),
      const SizedBox(height: 16),
      if (_connectionError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(_connectionError!, style: const TextStyle(color: Colors.red, fontSize: 13)),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('Connection successful!', style: TextStyle(color: Colors.green, fontSize: 13)),
        ),
      Row(
        children: [
          ElevatedButton.icon(
            onPressed: () => _showPairingDialog(context),
            icon: const Icon(Icons.phonelink_setup),
            label: const Text('Pair New Device'),
          ),
          const Spacer(),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          ElevatedButton(
            onPressed: _isTestingConnection ? null : () async {
              final baseUrl = _baseUrlController.text.trim();
              if (baseUrl.isEmpty) {
                setState(() => _connectionError = 'Server URL is required');
                return;
              }

              setState(() {
                _isTestingConnection = true;
                _connectionError = null;
              });

              try {
                // Temporary config for testing
                final testConfig = RomMConfig(
                  baseUrl: baseUrl,
                  username: _usernameController.text.trim(),
                  password: _passwordController.text,
                  apiKey: _pairedToken == null ? _apiKeyController.text.trim() : '',
                  token: _pairedToken,
                );
                
                final testService = RommService(testConfig);
                await testService.getPlatforms(); // Simple connectivity test
                
                if (mounted) {
                  setState(() {
                    _isTestingConnection = false;
                  });
                }
              } catch (e) {
                if (mounted) {
                  setState(() {
                    _isTestingConnection = false;
                    _connectionError = 'Connection failed: ${e.toString().split('\n').first}';
                  });
                }
              }
            },
            child: _isTestingConnection 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Test Connection'),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final prefs = ref.read(sharedPreferencesProvider);
              await prefs.setString('rommBaseUrl', _baseUrlController.text.trim());
              if (_isLegacyAuth) {
                 await prefs.setString('rommUsername', _usernameController.text.trim());
                 await SecureStorageService.write('rommPassword', _passwordController.text, prefs);
                 await SecureStorageService.delete('rommApiKey', prefs);
                 await SecureStorageService.delete('rommAuthToken', prefs);
              } else if (_pairedToken != null) {
                 await SecureStorageService.write('rommAuthToken', _pairedToken!, prefs);
                 await SecureStorageService.delete('rommApiKey', prefs);
                 await prefs.setString('rommUsername', '');
                 await SecureStorageService.delete('rommPassword', prefs);
              } else {
                 await SecureStorageService.write('rommApiKey', _apiKeyController.text.trim(), prefs);
                 await SecureStorageService.delete('rommAuthToken', prefs);
                 await prefs.setString('rommUsername', '');
                 await SecureStorageService.delete('rommPassword', prefs);
              }
              _pairedToken = null;
              ref.invalidate(rommConfigProvider);
              ref.invalidate(rommServiceProvider);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved.')));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ]);
  }

  // --- Storage Section ---
  Widget _buildStorageSection(DirectoryService directoryService) {
    final preset = directoryService.linuxSyncPreset;
    
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Storage', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      
      if (io.Platform.isLinux) ...[
        const Text('Linux App Layout', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey(preset),
          initialValue: preset,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'default', child: Text('Manual / Native')),
            DropdownMenuItem(value: 'emudeck', child: Text('EmuDeck')),
            DropdownMenuItem(value: 'retrodeck', child: Text('RetroDeck')),
          ],
          onChanged: (val) async {
            if (val != null) {
              await directoryService.setLinuxSyncPreset(val);
              ref.invalidate(directoryServiceProvider);
            }
          },
        ),
        const SizedBox(height: 16),
      ],

      if (io.Platform.isLinux && (preset == 'emudeck' || preset == 'retrodeck')) ...[
        _buildPathRow(
          label: '${preset == 'emudeck' ? 'EmuDeck' : 'RetroDeck'} Installation Root',
          currentPath: directoryService.linuxPresetRootPath ?? 'Not set',
          onChanged: (p) async { 
            if (p != null) { 
              await directoryService.setLinuxPresetRoot(p);
              ref.invalidate(directoryServiceProvider); 
            } 
          },
        ),
        const SizedBox(height: 16),
        const Text('Computed Paths (Read-only)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        _buildPathRow(
          label: 'ROMs Directory',
          currentPath: directoryService.romsRootPath,
          onChanged: null,
        ),
      ] else ...[
        // This handles both non-Linux OSs and Linux 'Manual' mode
        _buildPathRow(
          label: 'ROMs Directory',
          currentPath: directoryService.romsRootPath,
          onChanged: (p) async {
            if (p != null) {
              await directoryService.setRomsRoot(p);
              ref.invalidate(directoryServiceProvider);
            }
          },
          onReset: () async {
            await directoryService.resetRomsRoot();
            ref.invalidate(directoryServiceProvider);
          },
        ),
        const SizedBox(height: 16),
        _buildPathRow(
          label: 'Downloads Root',
          currentPath: directoryService.romsRootPath,
          onChanged: null,
        ),
      ],

      _buildPathRow(
        label: 'Emulators Directory',
        currentPath: directoryService.emulatorsRootPath,
        onChanged: (p) async { 
          if (p != null) { 
            await directoryService.setEmulatorsRoot(p); 
            ref.invalidate(directoryServiceProvider); 
          } 
        },
        onReset: () async { 
          await directoryService.resetEmulatorsRoot(); 
          ref.invalidate(directoryServiceProvider); 
        },
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: () => SystemUtils.openDirectory(directoryService.romsRootPath),
        icon: const Icon(Icons.folder_open),
        label: const Text('Open ROMs Directory'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: SystemUtils.openAppDataDirectory,
        icon: const Icon(Icons.folder_open),
        label: const Text('Open App Data Directory'),
      ),
      const SizedBox(height: 16),
      const Divider(color: Colors.white10),
      const SizedBox(height: 8),
      const Text('Troubleshooting', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      const SizedBox(height: 8),
      const Text('If games are missing from your offline library, try a full scan.', style: TextStyle(color: Colors.white54, fontSize: 13)),
      const SizedBox(height: 12),
      Consumer(builder: (context, ref, _) {
        final isScanning = ref.watch(isScanningProvider);
        return OutlinedButton.icon(
          onPressed: isScanning ? null : () async {
            await ref.read(downloadedGamesCacheProvider.notifier).startIncrementalSync(force: true);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Full ROM scan complete.')));
            }
          },
          icon: isScanning 
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.sync),
          label: Text(isScanning ? 'Scanning...' : 'Force Full ROM Scan'),
        );
      }),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => _showLogsDialog(context),
        icon: const Icon(Icons.receipt_long),
        label: const Text('View Console Logs'),
      ),
    ]);
  }

  void _showLogsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const _LogsDialogContent(),
    );
  }

  Widget _buildPathRow({required String label, required String currentPath, required Function(String?)? onChanged, VoidCallback? onReset}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      Row(children: [
        Expanded(child: Text(currentPath, overflow: TextOverflow.ellipsis)),
        if (onReset != null) IconButton(onPressed: onReset, icon: const Icon(Icons.restore)),
        if (onChanged != null) ElevatedButton(onPressed: () async => onChanged(await FilePicker.platform.getDirectoryPath()), child: const Text('Change')),
      ]),
    ]);
  }

  Widget _buildLinuxSettingsSection(BuildContext context, WidgetRef ref, DirectoryService directoryService) => const SizedBox();
  Widget _buildLegalSection(BuildContext context) {
    return Column(
      children: [
        const Divider(color: Colors.white10),
        const SizedBox(height: 16),
        Text(
          'Freegosy v${AppConstants.version}',
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'Freegosy',
            applicationVersion: AppConstants.version,
            applicationIcon: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Image.asset('freegosy_logo.png', height: 64, width: 64),
            ),
          ),
          child: const Text('View Licenses'),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  void _showPairingDialog(BuildContext context) {
    final codeController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pair with Web UI'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the 8-digit code generated in your RomM Web UI settings.'),
            const SizedBox(height: 16),
            TextField(
              controller: codeController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Pairing Code',
                hintText: 'XXXXXXXX',
                border: OutlineInputBorder(),
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 4, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final code = codeController.text.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
              if (code.length < 8) return;
              
              try {
                final url = _baseUrlController.text.trim();
                if (url.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a Server URL first.')));
                  return;
                }
                final token = await RommService.exchangePairingCode(url, code);
                _apiKeyController.text = token;
                setState(() => _isLegacyAuth = false);
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Successfully paired! Click Save to apply.')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Pairing failed: ${e.toString().split('\n').first}')));
                }
              }
            },
            child: const Text('Pair'),
          ),
        ],
      ),
    );
  }
}

class _LogsDialogContent extends StatefulWidget {
  const _LogsDialogContent();

  @override
  State<_LogsDialogContent> createState() => _LogsDialogContentState();
}

class _LogsDialogContentState extends State<_LogsDialogContent> {
  String _filter = 'ALL';
  final ScrollController _scrollController = ScrollController();

  String _maskIPs(String text) {
    final ipRegex = RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b');
    return text.replaceAll(ipRegex, '***.***.***.***');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 800),
        height: MediaQuery.of(context).size.height * 0.8,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('System Logs', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.delete_sweep),
                      onPressed: () => LoggerService().clear(),
                      tooltip: 'Clear Logs',
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterChip(label: 'ALL', selected: _filter == 'ALL', onSelected: () => setState(() => _filter = 'ALL')),
                  const SizedBox(width: 8),
                  _FilterChip(label: 'SCANNER', selected: _filter == 'SCANNER', onSelected: () => setState(() => _filter = 'SCANNER')),
                  const SizedBox(width: 8),
                  _FilterChip(label: 'NETWORK', selected: _filter == 'NETWORK', onSelected: () => setState(() => _filter = 'NETWORK')),
                  const SizedBox(width: 8),
                  _FilterChip(label: 'REGISTRY', selected: _filter == 'REGISTRY', onSelected: () => setState(() => _filter = 'REGISTRY')),
                  const SizedBox(width: 8),
                  _FilterChip(label: 'DIRECTORY', selected: _filter == 'DIRECTORY', onSelected: () => setState(() => _filter = 'DIRECTORY')),
                  const SizedBox(width: 8),
                  _FilterChip(label: 'ERROR', selected: _filter == 'ERROR', onSelected: () => setState(() => _filter = 'ERROR')),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: StreamBuilder<List<LogEntry>>(
                stream: LoggerService().logStream,
                initialData: LoggerService().logs,
                builder: (context, snapshot) {
                  final allLogs = snapshot.data ?? [];
                  final filteredLogs = allLogs.where((log) {
                    final msg = log.toString().toUpperCase();
                    if (_filter == 'ALL') return true;
                    if (_filter == 'SCANNER') return msg.contains('[SCAN]') || msg.contains('[ROM SCANNER]');
                    if (_filter == 'NETWORK') return msg.contains('[NETWORK]') || msg.contains('[ROMMSERVICE]') || msg.contains('[ROMM-NETWORK]');
                    if (_filter == 'REGISTRY') return msg.contains('[REGISTRY]');
                    if (_filter == 'DIRECTORY') return msg.contains('[DIRECTORYSERVICE]');
                    if (_filter == 'ERROR') return msg.contains('ERROR') || msg.contains('FAILED') || msg.contains('EXCEPTION') || msg.contains(' 404') || msg.contains(' 403') || msg.contains(' 500');
                    return true;
                  }).toList();

                  final fullText = _maskIPs(filteredLogs.map((e) => e.toString()).join('\n'));

                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectionArea(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            fullText,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  const _FilterChip({required this.label, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: selected,
      onSelected: (_) => onSelected(),
      visualDensity: VisualDensity.compact,
    );
  }
}
