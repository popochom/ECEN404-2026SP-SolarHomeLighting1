
import "package:flutter/material.dart";
import 'package:shared_preferences/shared_preferences.dart';
import "package:firebase_core/firebase_core.dart";
import "package:firebase_database/firebase_database.dart";
import "package:firebase_auth/firebase_auth.dart";
import "dart:async";
import 'package:fl_chart/fl_chart.dart';
import 'dart:math' as math;
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:gallery_saver_plus/gallery_saver.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Global userKey variable
String? userKey;

// Load userKey from local storage at app start
Future<void> loadUserKey() async {
  final prefs = await SharedPreferences.getInstance();
  userKey = prefs.getString('userKey');
}

/*
App layout:
  Login Page:
    - email & password fields
    - login button
    - create account button

  Main page:
    - simplified view of power data (Battery Capacity, Current Wattage, etc.)
    - buttons (or side menu?) to open other menus
    - local weather data
  
  Power Data:
    - display detailed power data
    - Panel & Battery Temperature sensor data
    - Error/Breaker Trip notifications

  Light Controls:
    - Customizable array of switch buttons
    - Edit mode to add/remove/rename switches
    - Status of each switch (on/off)

  Camera Recordings:
    - view recent recording (thumbnail & timestamp)
    - download videos for watching on device.
      - in app video player?

  About:
    - Problem Statement
    - Brief description of app

  Settings:
    - Set location
    - dark/light mode
    - other user preferences

Helper functions:
  Firebase Access/Interaction:
    - Get information
    - Set information
    - download video data

  Power Info:
    - graph generation data, battery capacity, loads, etc
    -


*/

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await loadUserKey();
  runApp(SolarHomeLighting());
}


//Main App
class SolarHomeLighting extends StatefulWidget {
  const SolarHomeLighting({super.key});

  static const appTitle = "Solar Home Lighting Monitor";

  @override
  State<SolarHomeLighting> createState() => _SolarHomeLightingState();
}

class _SolarHomeLightingState extends State<SolarHomeLighting> {

  ThemeMode _themeMode = ThemeMode.system;
  static final FlutterLocalNotificationsPlugin _ln = FlutterLocalNotificationsPlugin();
  bool _autoDarkMode = false;
  StreamSubscription<DatabaseEvent>? _luxSub;
  bool _autoDarkModeLoading = false;

  @override
  void initState() {
    super.initState();
    _initLocalNotifications();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptNotificationPermissionWithExplanation();
    });
    _loadAutoDarkMode();
  }
  @override
  void dispose() {
    _luxSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAutoDarkMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final val = prefs.getBool('autoDarkMode');
      setState(() {
        _autoDarkMode = val ?? false;
      });
      _setupLuxListener();
    } catch (_) {}
  }

  void _setupLuxListener() {
    _luxSub?.cancel();
    if (!_autoDarkMode) return;
    final db = userRef();
    _luxSub = db.child('sensorData').child('lux').onValue.listen((event) {
      final v = event.snapshot.value;
      double lux = 100.0;
      if (v is num) lux = v.toDouble();
      else if (v is String) lux = double.tryParse(v) ?? 100.0;
      if (_autoDarkMode) {
        final shouldBeDark = lux < 10;
        final isDark = (_themeMode == ThemeMode.dark);
        if (shouldBeDark != isDark) {
          setState(() {
            _themeMode = shouldBeDark ? ThemeMode.dark : ThemeMode.light;
          });
        }
      }
    });
  }

  Future<void> _setAutoDarkMode(bool enabled) async {
    setState(() {
      _autoDarkMode = enabled;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoDarkMode', enabled);
    _setupLuxListener();
    if (enabled) {
      await _checkLuxAndSetTheme();
    }
  }

  Future<void> _checkLuxAndSetTheme() async {
    setState(() => _autoDarkModeLoading = true);
    try {
      final luxSnap = await userRef().child('sensorData').child('lux').get();
      double lux = 100.0;
      if (luxSnap.exists) {
        final v = luxSnap.value;
        if (v is num) lux = v.toDouble();
        else if (v is String) lux = double.tryParse(v) ?? 100.0;
      }
      setState(() {
        _themeMode = (lux < 10) ? ThemeMode.dark : ThemeMode.light;
      });
    } catch (_) {}
    setState(() => _autoDarkModeLoading = false);
  }

  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    final initSettings = InitializationSettings(android: androidSettings);
    await _ln.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        final payload = response.payload;
        if (payload == 'recordings') {
          // Try to switch tab immediately if home is active
          final st = MyHomePage.navKey.currentState;
          if (st is _MyHomePageState) {
            st.setTab(3);
          } else {
            // Fallback: mark pending selection for next build
            MyHomePage.lastSelectedIndex = 3;
            MyHomePage.pendingNavigateToRecordings = true;
          }
        }
      },
    );
    const androidChannel = AndroidNotificationChannel(
      'motion_alerts',
      'Motion Alerts',
      description: 'Notifications when motion is detected',
      importance: Importance.high,
    );
    final androidPlugin = _ln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(androidChannel);
  }

  Future<void> _promptNotificationPermissionWithExplanation() async {
    try {
      if (!(Platform.isAndroid || Platform.isIOS)) return;
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow Notifications?'),
          content: const Text(
            'Enable notifications to be alerted when motion is detected.\n' 
            'You can change this anytime in Settings → Notify of activity.'
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Allow')),
          ],
        ),
      );
      if (proceed == true) {
        final status = await Permission.notification.request();
        if (!status.isGranted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Notifications disabled — you can enable later in Settings')),
          );
        }
      }
    } catch (_) {}
  }

  void _setDarkMode(bool enabled) {
    setState(() {
      _themeMode = enabled ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    final light = ThemeData(
      brightness: Brightness.light,
      primaryColor: const Color.fromARGB(255, 128, 0, 0),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color.fromARGB(255, 128, 0, 0),
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 20),
        centerTitle: true,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.all(Colors.grey),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color.fromARGB(255, 128, 0, 0),
          foregroundColor: Colors.white,
        ),
      ),
    );

    final dark = ThemeData.dark().copyWith(
      primaryColor: const Color.fromARGB(255, 128, 0, 0),
      scaffoldBackgroundColor: const Color(0xFF121212),
      cardColor: const Color(0xFF1E1E1E),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color.fromARGB(255, 128, 0, 0),
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 20),
        centerTitle: true,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.tealAccent),
        trackColor: WidgetStateProperty.all(Colors.teal),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color.fromARGB(255, 128, 0, 0),
          foregroundColor: Colors.white,
        ),
      ),
    );

    return MaterialApp(
      title: SolarHomeLighting.appTitle,
      theme: light,
      darkTheme: dark,
      themeMode: _themeMode,
      home: AuthGate(
        themeMode: _themeMode,
        onThemeChanged: (bool dark) {
          if (_autoDarkMode) return; // ignore manual toggle if auto is on
          _setDarkMode(dark);
        },
        ln: _ln,
        autoDarkMode: _autoDarkMode,
        onAutoDarkModeChanged: _setAutoDarkMode,
        autoDarkModeLoading: _autoDarkModeLoading,
      ),
    );
  }
}

// Authentication gate: shows LoginPage when not signed-in, otherwise the main app

class AuthGate extends StatelessWidget {
  final ThemeMode themeMode;
  final void Function(bool) onThemeChanged;
  final FlutterLocalNotificationsPlugin ln;
  final bool autoDarkMode;
  final Future<void> Function(bool)? onAutoDarkModeChanged;
  final bool autoDarkModeLoading;

  const AuthGate({super.key, required this.themeMode, required this.onThemeChanged, required this.ln, required this.autoDarkMode, this.onAutoDarkModeChanged, this.autoDarkModeLoading = false});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (snapshot.hasData && snapshot.data != null) {
          // Signed in
          return MyHomePage(
            key: MyHomePage.navKey,
            title: SolarHomeLighting.appTitle,
            themeMode: themeMode,
            onThemeChanged: onThemeChanged,
            ln: ln,
            autoDarkMode: autoDarkMode,
            onAutoDarkModeChanged: onAutoDarkModeChanged,
            autoDarkModeLoading: autoDarkModeLoading,
          );
        }

        return const LoginPage();
      },
    );
  }
}

// Simple Login page using Firebase Auth (email/password)
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _loading = false;

  Future<void> _showMessage(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _signIn() async {
    setState(() => _loading = true);
    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      // Always reload userKey from Firebase and update local/global
      final uid = cred.user?.uid;
      if (uid != null) {
        final ref = FirebaseDatabase.instance.ref().child('solar_data').child('users').child(uid).child('userKey');
        final snap = await ref.get();
        userKey = snap.value?.toString() ?? uid;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('userKey', userKey!);
      }
    } on FirebaseAuthException catch (e) {
      await _showMessage(e.message ?? 'Sign-in failed');
    } catch (_) {
      await _showMessage('Sign-in failed');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _register() async {
    setState(() => _loading = true);
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      // On successful account creation, import the default data template
      // into the new user's subtree: solar_data/users/<uid>
      final user = cred.user;
      if (user != null) {
        try {
          final uid = user.uid;
          final ref = FirebaseDatabase.instance.ref().child('solar_data').child('users').child(uid);
          await ref.set(_dataTemplate);
          // Generate and store a userKey for new users
          final newUserKey = uid; // Or use a more complex key if needed
          await ref.child('userKey').set(newUserKey);
          userKey = newUserKey;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('userKey', userKey!);
        } catch (e) {
          // If writing the template fails, still consider the account created,
          // but inform the user.
          await _showMessage('Account created but failed to initialize user data');
          if (mounted) setState(() => _loading = false);
          return;
        }
      }

      // Force reload userKey from Firebase after registration
      final uid = cred.user?.uid;
      if (uid != null) {
        final ref = FirebaseDatabase.instance.ref().child('solar_data').child('users').child(uid).child('userKey');
        final snap = await ref.get();
        userKey = snap.value?.toString() ?? uid;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('userKey', userKey!);
      }

      await _showMessage('Account created — signed in');
    } on FirebaseAuthException catch (e) {
      await _showMessage(e.message ?? 'Account creation failed');
    } catch (_) {
      await _showMessage('Account creation failed');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      await _showMessage('Enter your email to reset password');
      return;
    }

    setState(() => _loading = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      await _showMessage('Password reset email sent');
    } on FirebaseAuthException catch (e) {
      await _showMessage(e.message ?? 'Failed to send reset email');
    } catch (_) {
      await _showMessage('Failed to send reset email');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Welcome', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: 'Email'),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _loading ? null : _signIn,
                  child: _loading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Log in'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _loading ? null : _register,
                  child: const Text('Create account'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _loading ? null : _resetPassword,
                  child: const Text('Forgot password?'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.title,
    required this.themeMode,
    required this.onThemeChanged,
    required this.ln,
    required this.autoDarkMode,
    this.onAutoDarkModeChanged,
    this.autoDarkModeLoading = false,
  });

  final String title;
  final ThemeMode themeMode;
  final void Function(bool) onThemeChanged;
  final FlutterLocalNotificationsPlugin ln;
  final bool autoDarkMode;
  final Future<void> Function(bool)? onAutoDarkModeChanged;
  final bool autoDarkModeLoading;

  // Persist last selected tab across widget rebuilds (e.g., theme changes)
  static int lastSelectedIndex = 0;
  static bool pendingNavigateToRecordings = false;
  static final GlobalKey navKey = GlobalKey();

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _selectedIndex = MyHomePage.lastSelectedIndex;
  final database = userRef();
  int? _requestedMetricIndex;
  int? _requestedIntervalIndex;
  StreamSubscription<DatabaseEvent>? _motionSub;
  StreamSubscription<DatabaseEvent>? _activityPrefSub;
  StreamSubscription<DatabaseEvent>? _motionWatchSub;
  StreamSubscription<DatabaseEvent>? _humanWatchSub;
  bool _notifyOfActivity = false;
  int _nightLightPref = 0;
  bool _lastMotion = false;
  bool _lastHuman = false;

  @override
  void initState() {
    super.initState();
    _subscribeActivitySettings();
    if (MyHomePage.pendingNavigateToRecordings) {
      MyHomePage.pendingNavigateToRecordings = false;
      _selectedIndex = 3;
    }
  }

  void _subscribeActivitySettings() {
    // Listen for changes to notifyOfActivity and nightLightPref
    _activityPrefSub?.cancel();
    final db = userRef();
    _activityPrefSub = db.child('settings').onValue.listen((event) {
      final snap = event.snapshot.value;
      bool notify = false;
      int nightPref = 0;
      if (snap is Map) {
        final n = snap['notifyOfActivity'];
        notify = n is bool ? n : (n is String ? n.toLowerCase() == 'true' : (n is num ? n != 0 : false));
        final v = snap['nightLightPref'];
        if (v is int) nightPref = v;
        else if (v is String) nightPref = int.tryParse(v) ?? 0;
      }
      setState(() {
        _notifyOfActivity = notify;
        _nightLightPref = nightPref;
      });
      _subscribeMotionOrHuman();
    });
  }

  void _subscribeMotionOrHuman() {
    _motionWatchSub?.cancel();
    _humanWatchSub?.cancel();
    final db = userRef();
    if (!_notifyOfActivity) {
      _lastMotion = false;
      _lastHuman = false;
      return;
    }
    if (_nightLightPref == 1) {
      // Listen for motion
      _motionWatchSub = db.child('sensorData').child('motion').onValue.listen((event) {
        final v = event.snapshot.value;
        final isMotion = v == true || (v is String && v.toLowerCase() == 'true') || (v is num && v != 0);
        if (!_lastMotion && isMotion) {
          _showMotionNotification(type: 'Motion Detected');
        }
        _lastMotion = isMotion;
      });
      _lastHuman = false;
    } else if (_nightLightPref == 2) {
      // Listen for human activity
      _humanWatchSub = db.child('sensorData').child('humanActivity').child('detected').onValue.listen((event) {
        final v = event.snapshot.value;
        final isHuman = v == true || (v is String && v.toLowerCase() == 'true') || (v is num && v != 0);
        if (!_lastHuman && isHuman) {
          _showMotionNotification(type: 'Human Activity Detected');
        }
        _lastHuman = isHuman;
      });
      _lastMotion = false;
    } else {
      _lastMotion = false;
      _lastHuman = false;
    }
  }

  Future<void> _showMotionNotification({String type = 'Motion Detected'}) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'motion_alerts',
        'Motion Alerts',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: false,
        autoCancel: true,
      ),
    );
    await widget.ln.show(1001, type, 'Motion has been detected', details, payload: 'recordings');
  }

  @override
  void dispose() {
    _motionSub?.cancel();
    _activityPrefSub?.cancel();
    _motionWatchSub?.cancel();
    _humanWatchSub?.cancel();
    super.dispose();
  }

  Widget _buildPage(int index) {
    switch (index) {
      case 0:
        return LandingPage(onNavigateToPage: (page, {int? metricIndex, int? intervalIndex}) {
          setState(() {
            _selectedIndex = page;
            _requestedMetricIndex = metricIndex;
            _requestedIntervalIndex = intervalIndex;
          });
        });
      case 1:
        return PowerDataPage(initialMetricIndex: _requestedMetricIndex, initialIntervalIndex: _requestedIntervalIndex);
      case 2:
        return const LightControlsPage();
      case 3:
        return const CameraRecordingsPage();
      case 4:
        return const AboutPage();
      case 5:
        return SettingsPage(
          themeMode: widget.themeMode,
          onThemeChanged: widget.onThemeChanged,
          onNotifyPrefChanged: (b) {
            setState(() => _notifyOfActivity = b);
          },
          autoDarkMode: widget.autoDarkMode,
          onAutoDarkModeChanged: widget.onAutoDarkModeChanged,
          autoDarkModeLoading: widget.autoDarkModeLoading,
        );
      default:
        return const LandingPage();
    }
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      MyHomePage.lastSelectedIndex = index;
    });
  }

  // Expose method to programmatically change tab (used by notification tap)
  void setTab(int index) {
    _onItemTapped(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          style: TextStyle(
            //fontWeight: FontWeight.bold,
            fontSize: 20,
            color: Colors.white,
          )
        ),
        centerTitle: true,
        backgroundColor: Color.fromARGB(255, 128, 0, 0),
        leading: Builder(
          builder: (context) {
            return IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () {
                Scaffold.of(context).openDrawer();
              },
            );
          },
        ),
      ),
  body: Center(child: _buildPage(_selectedIndex)),
      drawer: Drawer(
        child: Column(
          children: [
            // Header + scrollable list
            SizedBox(
              width: double.infinity,
              child: const DrawerHeader(
                decoration: BoxDecoration(color: Color.fromARGB(255, 128, 0, 0)),
                margin: EdgeInsets.zero,
                padding: EdgeInsets.all(16),
                child: Text(
                  'Solar \nHome \nLighting \nMonitor',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    leading: const Icon(Icons.home),
                    title: const Text('Home'),
                    selected: _selectedIndex == 0,
                    onTap: () {
                      _onItemTapped(0);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.bolt),
                    title: const Text('Power Data'),
                    selected: _selectedIndex == 1,
                    onTap: () {
                      _onItemTapped(1);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.lightbulb),
                    title: const Text('Light Controls'),
                    selected: _selectedIndex == 2,
                    onTap: () {
                      _onItemTapped(2);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.videocam),
                    title: const Text('Recordings'),
                    selected: _selectedIndex == 3,
                    onTap: () {
                      _onItemTapped(3);
                      Navigator.pop(context);
                    },
                  ),
                  const Divider(
                    height: 20,
                    thickness: 2,
                    indent: 20,
                    endIndent: 20,
                    color: Colors.grey,
                  ),
                  ListTile(
                    leading: const Icon(Icons.info),
                    title: const Text('About'),
                    onTap: () {
                      _onItemTapped(4);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings),
                    title: const Text('Settings'),
                    onTap: () {
                      _onItemTapped(5);
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),

            // Bottom sign-out button
            SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('Sign out'),
                    onTap: () async {
                      try {
                        await FirebaseAuth.instance.signOut();
                      } catch (e) {
                        // ignore sign-out errors — auth state will update if successful
                      }
                      // Close the drawer
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

//Landing Page
class LandingPage extends StatefulWidget {
  final void Function(int page, {int? metricIndex, int? intervalIndex})? onNavigateToPage;

  const LandingPage({super.key, this.onNavigateToPage});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  // Firebase-backed power values
  double _generation = 0.0;
  double _battery = 0.0;
  double _usage = 0.0;
  double _efficiency = 0.0;
  // Configurable maxima (from settings)
  double _panelMax = 1000.0;
  double _batteryMax = 100.0;

  // Brightness (lux) state
  double? _lux;
  StreamSubscription<DatabaseEvent>? _luxSub;

  StreamSubscription<DatabaseEvent>? _genSub;
  StreamSubscription<DatabaseEvent>? _batSub;
  StreamSubscription<DatabaseEvent>? _useSub;
  StreamSubscription<DatabaseEvent>? _sensorSub;
  StreamSubscription<DatabaseEvent>? _panelMaxSub;
  StreamSubscription<DatabaseEvent>? _batteryMaxSub;

  @override
  void initState() {
    super.initState();
    _startPowerListeners();
    _startLuxListener();
  }

  void _startLuxListener() {
    _luxSub?.cancel();
    final db = userRef();
    _luxSub = db.child('sensorData').child('lux').onValue.listen((event) {
      final v = event.snapshot.value;
      double lux = 100.0;
      if (v is num) lux = v.toDouble();
      else if (v is String) lux = double.tryParse(v) ?? 100.0;
      if (mounted) setState(() => _lux = lux);
    }, onError: (_) {});
  }

  void _startPowerListeners() {
    final db = userRef();

    _genSub = db.child('powerData').child('pin_w').onValue.listen((event) {
      final v = _parseFirebaseNumeric(event.snapshot.value);
      if (mounted) setState(() => _generation = v);
    }, onError: (_){ });

    _batSub = db.child('powerData').child('battery_pct').onValue.listen((event) {
      final v = _parseFirebaseNumeric(event.snapshot.value);
      if (mounted) setState(() => _battery = v);
    }, onError: (_){ });

    _useSub = db.child('powerData').child('pout_w').onValue.listen((event) {
      final v = _parseFirebaseNumeric(event.snapshot.value);
      if (mounted) setState(() => _usage = v);
    }, onError: (_){ });

    // listen for configurable maxima in settings
    _panelMaxSub = db.child('settings').child('panelSpecW').onValue.listen((event) {
      final v = _parseFirebaseNumeric(event.snapshot.value);
      if (v > 0 && mounted) setState(() => _panelMax = v);
    }, onError: (_){ });

    _batteryMaxSub = db.child('settings').child('batteryCapacityMax').onValue.listen((event) {
      final v = _parseFirebaseNumeric(event.snapshot.value);
      if (v > 0 && mounted) setState(() => _batteryMax = v);
    }, onError: (_){ });

    // Conversion efficiency (%)
    _sensorSub = db.child('powerData').child('eff_pct').onValue.listen((event) {
      final v = _parseFirebaseNumeric(event.snapshot.value);
      if (mounted) setState(() => _efficiency = v);
    }, onError: (_){ });
  }

  Future<void> _manualRefresh() async {
    try {
      final db = userRef();
      final genSnap = await db.child('powerData').child('pin_w').get();
      final batSnap = await db.child('powerData').child('battery_pct').get();
      final useSnap = await db.child('powerData').child('pout_w').get();
      final effSnap = await db.child('powerData').child('eff_pct').get();

      final gen = _parseFirebaseNumeric(genSnap.value);
      final bat = _parseFirebaseNumeric(batSnap.value);
      final use = _parseFirebaseNumeric(useSnap.value);
      final eff = _parseFirebaseNumeric(effSnap.value);

      if (mounted) {
        setState(() {
          _generation = gen;
          _battery = bat;
          _usage = use;
          _efficiency = eff;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to refresh data from Firebase')));
      }
    }
  }

  double _parseFirebaseNumeric(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  @override
  void dispose() {
    _genSub?.cancel();
    _batSub?.cancel();
    _useSub?.cancel();
    _panelMaxSub?.cancel();
    _batteryMaxSub?.cancel();
    _sensorSub?.cancel();
    _luxSub?.cancel();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget infoCard({required Widget child, required String title}) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colorScheme.onSurface)),
              const SizedBox(height: 8),
              Flexible(fit: FlexFit.loose, child: child),
            ],
          ),
        ),
      );
    }

    // Brightness widget
    Widget brightnessCard() {
      final lux = _lux;
      String label;
      if (lux == null) {
        label = "Brightness: (loading...)";
      } else {
        final isNight = lux < 10;
        label = "Brightness: ${isNight ? "Night" : "Day"} (Lux: ${lux.toStringAsFixed(0)})";
      }
      return Card(
        color: colorScheme.surfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18.0, horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.brightness_6, color: colorScheme.primary),
              const SizedBox(width: 12),
              Text(label, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: colorScheme.onSurface)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _manualRefresh,
                child: Column(
                  children: [
                    // Brightness widget at the top
                    brightnessCard(),
                    const SizedBox(height: 12),
                    // The rest of the grid
                    Expanded(
                      child: GridView.count(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        children: [
                          // Current Generation (watts)
                          GestureDetector(
                            onTap: () => widget.onNavigateToPage?.call(1, metricIndex: 0),
                            child: infoCard(
                              title: 'Current Generation (W)',
                              child: SpeedometerPlaceholder(value: _generation, max: _panelMax, unit: 'W'),
                            ),
                          ),

                          // Battery Capacity (percent)
                          GestureDetector(
                            onTap: () => widget.onNavigateToPage?.call(1, metricIndex: 1),
                            child: infoCard(
                              title: 'Battery Capacity (Ah)',
                              child: SpeedometerPlaceholder(value: (_battery / 100.0) * _batteryMax, max: _batteryMax, unit: 'Ah'),
                            ),
                          ),

                          // Power Usage (watts)
                          GestureDetector(
                            onTap: () => widget.onNavigateToPage?.call(1, metricIndex: 2),
                            child: infoCard(
                              title: 'Power Usage (W)',
                              child: SpeedometerPlaceholder(value: _usage, max: _panelMax, unit: 'W'),
                            ),
                          ),

                          // Conversion Efficiency (%)
                          GestureDetector(
                            onTap: () => widget.onNavigateToPage?.call(1, metricIndex: 3),
                            child: infoCard(
                              title: 'Conversion Efficiency (%)',
                              child: Center(
                                child: SpeedometerPlaceholder(value: _efficiency, max: 100, unit: '%'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Positioned(
              bottom: 8,
              right: 8,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: _manualRefresh,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Simple circular "speedometer" widget
class SpeedometerPlaceholder extends StatelessWidget {
  final double value;
  final double max;
  final String unit;

  const SpeedometerPlaceholder({super.key, required this.value, required this.max, required this.unit});

  @override
  Widget build(BuildContext context) {
    final pct = (value / max).clamp(0.0, 1.0);
    final primary = Theme.of(context).colorScheme.primary;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest.shortestSide;
      return Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: pct,
                strokeWidth: 12,
                color: primary,
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value.toStringAsFixed(value < 10 ? 1 : 0), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: onSurface)),
                const SizedBox(height: 4),
                Text(unit, style: TextStyle(fontSize: 12)),
              ],
            ),
          ],
        ),
      );
    });
  }
}


//Power Data Page
class PowerDataPage extends StatefulWidget {
  final int? initialMetricIndex;
  final int? initialIntervalIndex;

  const PowerDataPage({super.key, this.initialMetricIndex, this.initialIntervalIndex});

  @override
  State<PowerDataPage> createState() => _PowerDataPageState();
}

class _PowerDataPageState extends State<PowerDataPage> {
  StreamSubscription<DatabaseEvent>? _readingsSub;
  Map<String, dynamic> _readings = {};

  // Metrics the user can choose from
  final List<Map<String, String>> _metrics = [
    {"label": "Power (W)", "key": "power", "unit": "W"},
    {"label": "Capacity (Ah)", "key": "current", "unit": "Ah"},
    {"label": "Usage (W)", "key": "voltage", "unit": "W"},
    {"label": "Temperature (°C)", "key": "temperature", "unit": "°C"},
  ];
  int _metricIndex = 0;

  // Time interval options
  final List<Map<String, dynamic>> _intervals = [
    {"label": "30 mins", "dur": Duration(minutes: 30)},
    {"label": "1 hour", "dur": Duration(hours: 1)},
    {"label": "6 hours", "dur": Duration(hours: 6)},
    {"label": "24 hours", "dur": Duration(hours: 24)},
  ];
  int _intervalIndex = 2; // default 6 hours

  @override
  void initState() {
    super.initState();
    // initialize metric/interval from widget if provided
    if (widget.initialMetricIndex != null) _metricIndex = widget.initialMetricIndex!;
    if (widget.initialIntervalIndex != null) _intervalIndex = widget.initialIntervalIndex!;
    _subscribe();
  }

  void _subscribe() {
    _readingsSub?.cancel();
    _readingsSub = userRef().child('readings').onValue.listen((event) {
      final v = event.snapshot.value;
      if (v is Map) {
        setState(() => _readings = Map<String, dynamic>.from(v));
      } else {
        setState(() => _readings = {});
      }
    }, onError: (_) {
      setState(() => _readings = {});
    });
  }

  @override
  void dispose() {
    _readingsSub?.cancel();
    super.dispose();
  }

  // Build the key used by the DB: MMDDYYYYhhmm (UTC)
  String _keyForUtc(DateTime dt) {
    final t = dt.toUtc();
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    final yyyy = t.year.toString();
    final hh = t.hour.toString().padLeft(2, '0');
    final mi = t.minute.toString().padLeft(2, '0');
    return '$mm$dd$yyyy$hh$mi';
  }

  double _extract(dynamic entry, String key) {
    if (entry == null) return 0.0;
    if (entry is num) return entry.toDouble();
    if (entry is String) return double.tryParse(entry) ?? 0.0;
    if (entry is Map) {
      final v = entry[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0.0;
    }
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final metricKey = _metrics[_metricIndex]['key']!;
    final unit = _metrics[_metricIndex]['unit']!;
    final dur = _intervals[_intervalIndex]['dur'] as Duration;

    final end = DateTime.now().toUtc();
    final start = end.subtract(dur);
    final step = Duration(minutes: 5);

    // Floor start to nearest 5 minutes
    DateTime t = DateTime.utc(start.year, start.month, start.day, start.hour, (start.minute ~/ 5) * 5);
    if (t.isBefore(start)) t = t.add(step);

    final times = <DateTime>[];
    while (t.isBefore(end) || t.isAtSameMomentAs(end)) {
      times.add(t);
      t = t.add(step);
    }

    final spots = <FlSpot>[];
    for (var i = 0; i < times.length; i++) {
      final key = _keyForUtc(times[i]);
      final entry = _readings[key];
      final y = _extract(entry, metricKey);
      final x = times[i].difference(times.first).inMinutes.toDouble();
      spots.add(FlSpot(x, y));
    }

    final totalX = times.isNotEmpty ? times.last.difference(times.first).inMinutes.toDouble() : dur.inMinutes.toDouble();

    // Compute highest datapoint within last 24 hours for this metric
    double max24 = 0.0;
    final start24 = end.subtract(const Duration(hours: 24));
    DateTime tt = DateTime.utc(start24.year, start24.month, start24.day, start24.hour, (start24.minute ~/ 5) * 5);
    if (tt.isBefore(start24)) tt = tt.add(step);
    while (tt.isBefore(end) || tt.isAtSameMomentAs(end)) {
      final k = _keyForUtc(tt);
      final e = _readings[k];
      final v = _extract(e, metricKey);
      if (v > max24) max24 = v;
      tt = tt.add(step);
    }
    final yMax = (max24 <= 0) ? 1.0 : max24 * 1.5;

    // Constrain the visual chart area to a 4:3 landscape rectangle and not full-screen.
    final screenW = MediaQuery.of(context).size.width;
    final maxW = math.min(screenW * 0.95, 1000.0);

    return Scaffold(
      appBar: AppBar(title: const Text('Power Data')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButton<int>(
                    value: _metricIndex,
                    isExpanded: true,
                    items: List.generate(_metrics.length, (i) => DropdownMenuItem(value: i, child: Text(_metrics[i]['label']!))),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _metricIndex = v);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 160,
                  child: DropdownButton<int>(
                    value: _intervalIndex,
                    isExpanded: true,
                    items: List.generate(_intervals.length, (i) => DropdownMenuItem(value: i, child: Text(_intervals[i]['label'] as String))),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _intervalIndex = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Centered landscape card with aspect ratio 4:3
            Center(
              child: SizedBox(
                width: maxW,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('${_metrics[_metricIndex]['label']} — last ${_intervals[_intervalIndex]['label']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Expanded(
                            child: times.isEmpty
                                ? const Center(child: Text('No data range'))
                                : LineChart(
                                    LineChartData(
                                      minX: 0,
                                      maxX: totalX,
                                      minY: 0,
                                      maxY: yMax,
                                      lineBarsData: [
                                        LineChartBarData(
                                          spots: spots,
                                          isCurved: true,
                                          dotData: FlDotData(show: true),
                                          belowBarData: BarAreaData(show: false),
                                          color: Theme.of(context).colorScheme.primary,
                                          barWidth: 2,
                                        ),
                                      ],
                                      gridData: FlGridData(show: true),
                                      titlesData: FlTitlesData(
                                        bottomTitles: AxisTitles(
                                          sideTitles: SideTitles(
                                            showTitles: true,
                                            reservedSize: 40,
                                            interval: (totalX / 6).clamp(1, totalX),
                                            getTitlesWidget: (value, meta) {
                                              final dt = times.first.add(Duration(minutes: value.toInt()));
                                              final h = dt.hour.toString().padLeft(2, '0');
                                              final m = dt.minute.toString().padLeft(2, '0');
                                              return Padding(
                                                padding: const EdgeInsets.only(top: 8.0),
                                                child: Text('$h:$m', style: const TextStyle(fontSize: 10)),
                                              );
                                            },
                                          ),
                                        ),
                                        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 48)),
                                        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                      ),
                                      borderData: FlBorderData(show: true),
                                    ),
                                  ),
                          ),
                          const SizedBox(height: 8),
                          Text('Values shown in $unit', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


//Light Controls Page
class LightControlsPage extends StatefulWidget {
  const LightControlsPage({super.key});

  @override
  State<LightControlsPage> createState() => _LightControlsPageState();
}

class LightingControl {
  String name;
  bool isOn;
  int number; // 1-based index for lightN

  LightingControl({required this.name, this.isOn = false, required this.number});
}

class _LightControlsPageState extends State<LightControlsPage> {
    StreamSubscription<DatabaseEvent>? _lightsSub;
  final lightingControlsRef = userRef().child("lightingControls");
  static const int maxSwitches = 4; //matches number of relays on microcontroller, change as needed.

  final List<LightingControl> controls = [
    LightingControl(name: 'Porch', isOn: false, number: 1),
    LightingControl(name: 'Living Room', isOn: false, number: 2),
    LightingControl(name: 'Kitchen', isOn: false, number: 3),
    LightingControl(name: 'Patio', isOn: false, number: 4)
  ];

  @override
  void initState() {
    super.initState();
    _lightsSub = lightingControlsRef.onValue.listen((event) {
      final data = event.snapshot.value;
      if (data is Map) {
        setState(() {
          for (var c in controls) {
            final key = 'light${c.number}';
            if (data.containsKey(key)) {
              final v = data[key];
              c.isOn = v == true || (v is String && v.toLowerCase() == 'true') || (v is num && v != 0);
            }
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _lightsSub?.cancel();
    super.dispose();
  }

  bool _isEditing = false;

  void _toggleControl(int index, bool value) {
    setState(() {
      controls[index].isOn = value;
    });

    // Write the new state to Firebase under lightingControls/lightN
    try {
      final num = controls[index].number;
      lightingControlsRef.child('light$num').set(value);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to toggle — database unreachable')),
        );
      }
    }
  }

  void _addControl() {
    final messenger = ScaffoldMessenger.of(context);
    if (controls.length >= maxSwitches) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('All switches are in use'),
          content: const Text('All switches are in use, remove an existing switch and try again!'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    setState(() {
      final newNumber = controls.length + 1;
      final newName = 'Light $newNumber';
      controls.add(LightingControl(name: newName, isOn: false, number: newNumber));
    });
    // Try to persist a default OFF state in Firebase
    final idx = controls.length - 1;
    final num = controls[idx].number;
    lightingControlsRef.child('light$num').set(false).then((_) {
      messenger.showSnackBar(
        SnackBar(content: Text('Added "light$num"')),
      );
    }).catchError((_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Added locally, but failed to save to database')),
      );
    });
  }

  Future<void> _renameControl(int index) async {
    final messenger = ScaffoldMessenger.of(context);
    final oldName = controls[index].name;
    final controller = TextEditingController(text: oldName);
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Control'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Rename')),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != oldName) {
      setState(() {
        controls[index].name = result;
      });

      // Update Firebase: set new child value and remove old child
      try {
        final value = controls[index].isOn;
        final num = controls[index].number;
        await lightingControlsRef.child('light$num').set(value);
        await lightingControlsRef.child(oldName).remove();
        messenger.showSnackBar(
          SnackBar(content: Text('Renamed to "$result"')),
        );
      } catch (e) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Failed to rename control in database')),
        );
      }
    }
  }

  Future<void> _removeControl(int index) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = controls[index].name;
    final num = controls[index].number;
    final confirm = await showDialog<bool?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Control'),
        content: Text('Are you sure you want to remove "$name"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        controls.removeAt(index);
        // Re-number remaining controls
        for (int i = 0; i < controls.length; i++) {
          controls[i].number = i + 1;
        }
      });
      try {
        await lightingControlsRef.child('light$num').remove();
        messenger.showSnackBar(
          SnackBar(content: Text('Removed "$name"')),
        );
      } catch (e) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Failed to remove control')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: controls.length,
              itemBuilder: (context, index) {
                final c = controls[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.name,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              c.isOn ? 'Status: ON' : 'Status: OFF',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                        // When editing, show edit/delete icons; otherwise show the switch
                        _isEditing
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit),
                                    onPressed: () => _renameControl(index),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete),
                                    onPressed: () => _removeControl(index),
                                  ),
                                ],
                              )
                            : Switch(
                                value: c.isOn,
                                onChanged: (value) => _toggleControl(index, value),
                              ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ElevatedButton.icon(
                onPressed: () => setState(() => _isEditing = !_isEditing),
                icon: Icon(_isEditing ? Icons.check : Icons.edit),
                label: Text(_isEditing ? 'Done' : 'Edit Controls'),
                style: ElevatedButton.styleFrom(
                  // Ensure label and icon are white regardless of theme
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _addControl,
                icon: const Icon(Icons.add),
                label: const Text('Add Control'),
                style: ElevatedButton.styleFrom(
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


//Camera Recordings Page
class CameraRecordingsPage extends StatefulWidget {
  const CameraRecordingsPage({super.key});

  @override
  State<CameraRecordingsPage> createState() => _CameraRecordingsPageState();
}

class _CameraRecordingsPageState extends State<CameraRecordingsPage> {
    bool _motionStatus = false;
    bool _humanStatus = false;
    bool _sensorLoading = true;

    Future<void> _loadSensorStatus() async {
      setState(() => _sensorLoading = true);
      try {
        final db = userRef();
        final motionSnap = await db.child('sensorData').child('motion').get();
        final humanSnap = await db.child('sensorData').child('humanActivity').child('detected').get();
        bool motion = false;
        bool human = false;
        if (motionSnap.exists) {
          final v = motionSnap.value;
          motion = v == true || (v is String && v.toLowerCase() == 'true') || (v is num && v != 0);
        }
        if (humanSnap.exists) {
          final v = humanSnap.value;
          human = v == true || (v is String && v.toLowerCase() == 'true') || (v is num && v != 0);
        }
        setState(() {
          _motionStatus = motion;
          _humanStatus = human;
          _sensorLoading = false;
        });
      } catch (_) {
        setState(() => _sensorLoading = false);
      }
    }
  final FirebaseStorage _storage = FirebaseStorage.instance;
  List<Reference> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadList();
    _loadSensorStatus();
  }

  Future<void> _loadList() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final key = userKey ?? 'unknown';
      final ref = _storage.ref().child('recordings').child(key);
      final listResult = await ref.listAll();
      setState(() => _items = List<Reference>.from(listResult.items));
      await _loadSensorStatus();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to list recordings')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _ensurePermissions() async {
    // request relevant permissions for saving to external storage.
    try {
      bool granted = false;
      if (Platform.isAndroid) {
        final storage = await Permission.storage.request();
        // On Android 11+, requesting manageExternalStorage may be required
        final manage = await Permission.manageExternalStorage.request();
        granted = storage.isGranted || manage.isGranted;
      } else if (Platform.isIOS) {
        final photos = await Permission.photos.request();
        granted = photos.isGranted;
      } else {
        // For other platforms, attempt storage permission
        final storage = await Permission.storage.request();
        granted = storage.isGranted;
      }

      if (granted) return true;

      // Not granted — prompt user to open app settings to grant permission
      if (!mounted) return false;
      final open = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Permission required'),
          content: const Text('The app needs storage permissions to save recordings to your device. Open app settings to grant permission?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open settings')),
          ],
        ),
      );

      if (open == true) {
        await openAppSettings();
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _downloadAndSave(Reference ref) async {
    // Use GallerySaver to download/save video directly to gallery.
    if (!await _ensurePermissions()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Storage/photos permission required')));
      return;
    }

    try {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saving to gallery...')));
      final url = await ref.getDownloadURL();
      final ok = await GallerySaver.saveVideo(url, toDcim: true, albumName: 'Download');
      if (ok == true) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to gallery Downloads')));
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to save to gallery')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download/save failed')));
    }
  }

  Widget _buildItemTile(Reference ref) {
    return FutureBuilder<FullMetadata>(
      future: ref.getMetadata(),
      builder: (context, snap) {
  final sizeBytes = snap.data?.size ?? 0;
  final subtitle = snap.hasData ? '${(sizeBytes / 1024 / 1024).toStringAsFixed(2)} MB' : null;
        return ListTile(
          leading: const Icon(Icons.videocam),
          title: Text(ref.name),
          subtitle: subtitle != null ? Text(subtitle) : null,
          trailing: IconButton(icon: const Icon(Icons.download_rounded), onPressed: () => _downloadAndSave(ref)),
          onTap: () => _downloadAndSave(ref),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadList, tooltip: 'Refresh'),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('No recordings found'),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(onPressed: _loadList, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, index) => Card(child: _buildItemTile(_items[index])),
                      ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            child: _sensorLoading
                ? const Text('Loading sensor status...')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Motion Sensor: ${_motionStatus ? "Active" : "Inactive"}', style: TextStyle(fontSize: 16)),
                      Text('Human Activity Sensor: ${_humanStatus ? "Active" : "Inactive"}', style: TextStyle(fontSize: 16)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}


//About Page (stateless)
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.textTheme.bodyMedium?.color ?? theme.colorScheme.onSurface;
    final headingStyle = TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: textColor);
    final bodyStyle = TextStyle(fontSize: 16, height: 1.4, color: textColor);
    final labelStyle = TextStyle(fontWeight: FontWeight.bold, color: textColor);

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text('About Us', style: headingStyle),
            const SizedBox(height: 16),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(text: 'Problem statement:\n', style: labelStyle),
                  const TextSpan(text: 'Traditional Home lighting systems often lack remote monitoring and control capabilities, making it difficult for users to manage their energy consumption effectively.'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(text: 'Brief description:\n', style: labelStyle),
                  const TextSpan(text: 'This app serves as a user-friendly interface for monitoring and controlling your Solar Home Lighting system. It provides real-time data on power usage, battery status, and allows for easy control of connected lighting devices. Users can customize their lighting controls, view camera recordings, and adjust settings to suit their preferences.'),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

//Settings Page
class SettingsPage extends StatefulWidget {
  final ThemeMode themeMode;
  final void Function(bool) onThemeChanged;
  final void Function(bool)? onNotifyPrefChanged;
  final bool autoDarkMode;
  final Future<void> Function(bool)? onAutoDarkModeChanged;
  final bool autoDarkModeLoading;

  const SettingsPage({
    super.key,
    required this.themeMode,
    required this.onThemeChanged,
    this.onNotifyPrefChanged,
    required this.autoDarkMode,
    this.onAutoDarkModeChanged,
    this.autoDarkModeLoading = false,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _localUserKey;

  @override
  void initState() {
    super.initState();
    _loadNightPref();
    _panelController = TextEditingController();
    _batteryController = TextEditingController();
    _loadSpecs();
    _loadNotifyPref();
    _loadUserKeyLocal();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadUserKeyLocal();
  }

  Future<void> _loadUserKeyLocal() async {
    final prefs = await SharedPreferences.getInstance();
    String? stored = prefs.getString('userKey');
    setState(() {
      _localUserKey = stored ?? userKey;
    });
  }
  int _nightPref = 0;
  late TextEditingController _panelController;
  late TextEditingController _batteryController;
  bool _notifyOfActivity = false;
  @override
  void dispose() {
    _panelController.dispose();
    _batteryController.dispose();
    super.dispose();
  }

  Future<void> _loadSpecs() async {
    try {
      final db = userRef().child('settings');
      final panelSnap = await db.child('panelSpecW').get();
      if (panelSnap.exists) {
        final v = panelSnap.value;
        if (v != null) {
          final parsed = v is num ? v.toDouble() : double.tryParse(v.toString());
          if (parsed != null) _panelController.text = parsed.toString();
        }
      }

  final batSnap = await db.child('batteryCapacityMax').get();
      if (batSnap.exists) {
        final v = batSnap.value;
        if (v != null) {
          final parsed = v is num ? v.toDouble() : double.tryParse(v.toString());
          if (parsed != null) _batteryController.text = parsed.toString();
        }
      }
    } catch (e) {
      // ignore load errors
    }
  }

  Future<void> _loadNightPref() async {
    try {
      final snap = await userRef().child('settings').child('nightLightPref').get();
      if (snap.exists) {
        final val = snap.value;
        if (val is int) {
          setState(() => _nightPref = val);
        } else if (val is String) {
          final parsed = int.tryParse(val);
          if (parsed != null) setState(() => _nightPref = parsed);
        }
      }
    } catch (e) {
      // ignore load errors; keep default
    }
  }

  Future<void> _loadNotifyPref() async {
    try {
      final snap = await userRef().child('settings').child('notifyOfActivity').get();
      if (snap.exists) {
        final v = snap.value;
        final b = v is bool ? v : (v is String ? (v.toLowerCase() == 'true') : (v is num ? v != 0 : false));
        setState(() => _notifyOfActivity = b);
      }
    } catch (_) {}
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Dark mode tile moved to bottom of settings for easier access after other preferences.
          // Additional settings can be added here
          const SizedBox(height: 16),
          const SizedBox(height: 8),
          const Text('Solar Panel Specifications', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _panelController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Total Panel Wattage (W)',
              hintText: 'e.g. 1000.0',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _batteryController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Battery capacity (Ah)',
              hintText: 'e.g. 200.0',
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () async {
              final panelText = _panelController.text.trim();
              final batText = _batteryController.text.trim();
              final panelVal = double.tryParse(panelText);
              final batVal = double.tryParse(batText);
              if (panelVal == null || panelVal <= 0) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid panel spec')));
                return;
              }
              if (batVal == null || batVal <= 0) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid battery capacity')));
                return;
              }

              try {
                final settingsRef = userRef().child('settings');
                await settingsRef.child('panelSpecW').set(panelVal);
                await settingsRef.child('batteryCapacityMax').set(batVal);
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Specifications saved')));
              } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to save specifications')));
              }
            },
            style: ElevatedButton.styleFrom(
              foregroundColor: Colors.white,
            ),
            child: const Text('Save Specifications', style: TextStyle(color: Colors.white)),
          ),
          const Text('Night lighting mode', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            DropdownButton<int>(
              value: _nightPref, // Allow all menu items to be selected
              items: const [
                DropdownMenuItem(value: 0, child: Text('Off')),
                DropdownMenuItem(value: 4, child: Text('After Sunset')),
                DropdownMenuItem(value: 1, child: Text('Motion')),
                DropdownMenuItem(value: 2, child: Text('Human Activity')),
                DropdownMenuItem(value: 3, child: Text('Activity AND Motion')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                try {
                  await userRef().child('settings').child('nightLightPref').set(v);
                  setState(() => _nightPref = v);
                } catch (e) {
                  if(context.mounted){
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to save night lighting preference')));
                  }
                }
              },
            ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Notify of activity'),
            subtitle: const Text('Send a notification when selected activity is detected'),
            value: _notifyOfActivity,
            onChanged: (value) async {
              try {
                await userRef().child('settings').child('notifyOfActivity').set(value);
                // Set nightLightPref to 0 if notifications are off, else keep current (or default to 1)
                if (!value) {
                  await userRef().child('settings').child('nightLightPref').set(0);
                  setState(() => _nightPref = 0);
                } else {
                  // If turning on, set to 1 (motion) if not already 1 or 2
                  if (_nightPref != 1 && _nightPref != 2) {
                    await userRef().child('settings').child('nightLightPref').set(1);
                    setState(() => _nightPref = 1);
                  }
                }
                setState(() => _notifyOfActivity = value);
                widget.onNotifyPrefChanged?.call(value);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Failed to save notification preference')),
                  );
                }
              }
            },
            secondary: Icon(
              Icons.notifications_active,
              color: _notifyOfActivity ? Colors.green : null,
            ),
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            title: const Text('Automatic dark mode'),
            subtitle: const Text('Enable automatic theme switching based on ambient light'),
            value: widget.autoDarkMode,
            onChanged: (value) async {
              if (value == null || widget.onAutoDarkModeChanged == null) return;
              await widget.onAutoDarkModeChanged!(value);
              setState(() {});
            },
            secondary: const Icon(Icons.lightbulb_outline),
          ),
          SwitchListTile(
            title: const Text('Dark mode'),
            subtitle: const Text('Toggle between light and dark themes'),
            value: widget.themeMode == ThemeMode.dark,
            onChanged: (widget.autoDarkMode ? null : (value) async {
              // Update remote setting in Firebase
              try {
                final settingsRef = userRef().child('settings');
                await settingsRef.child('darkMode').set(value);
              } catch (e) {
                if(context.mounted){
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Failed to save setting to Firebase')),
                  );
                }
              }
              widget.onThemeChanged(value);
              setState(() {});
            }),
            secondary: const Icon(Icons.brightness_6),
            activeColor: widget.autoDarkMode ? Colors.grey : null,
          ),
          if (widget.autoDarkModeLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Checking ambient light...', style: TextStyle(color: Colors.grey)),
            ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'User Key: ${_localUserKey ?? userKey ?? "(not available)"}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16, color: Colors.grey),
                tooltip: 'Refresh User Key',
                onPressed: _loadUserKeyLocal,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

//database access under solar_data/users/<uid>
DatabaseReference userRef() {
  final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
  return FirebaseDatabase.instance.ref().child('solar_data').child('users').child(uid);
}

// Default user data template imported for new accounts.
const Map<String, dynamic> _dataTemplate = {
  "lightingControls": {
    "Kitchen": false,
    "Living Room": false,
    "Patio": false,
    "Porch": false,
  },
  "powerData": {
  "battery_pct": 39.6,
  "dac_code": 4095,
  "dac_v": 2.048,
  "eff_pct": 90,
  "iin_a": 1.888,
  "iout_a": 1.488,
  "kwh": 0.00014,
  "pin_w": 20.545,
  "pout_w": 18.49,
  "soc_pct": 39.6,
  "vcmd_v": 11,
  "vin_v": 10.881,
  "vout_v": 12.425,
  "wh": 0.141
  },
  "readings": {
    "111120251000": {"current": 0.56, "power": 10.0, "temperature": 18.0, "voltage": 18.0, "timestamp_human": "2025-11-11T10:00:00Z"},
    "111120251005": {"current": 0.69, "power": 12.5, "temperature": 18.4, "voltage": 18.0, "timestamp_human": "2025-11-11T10:05:00Z"},
    "111120251010": {"current": 0.83, "power": 15.0, "temperature": 18.8, "voltage": 18.0, "timestamp_human": "2025-11-11T10:10:00Z"},
    "111120251015": {"current": 0.97, "power": 17.5, "temperature": 19.2, "voltage": 18.0, "timestamp_human": "2025-11-11T10:15:00Z"},
    "111120251020": {"current": 1.11, "power": 20.0, "temperature": 19.6, "voltage": 18.0, "timestamp_human": "2025-11-11T10:20:00Z"},
    "111120251025": {"current": 1.25, "power": 22.5, "temperature": 20.0, "voltage": 18.0, "timestamp_human": "2025-11-11T10:25:00Z"},
    "111120251030": {"current": 1.39, "power": 25.0, "temperature": 20.4, "voltage": 18.0, "timestamp_human": "2025-11-11T10:30:00Z"},
    "111120251035": {"current": 1.53, "power": 27.5, "temperature": 20.8, "voltage": 18.0, "timestamp_human": "2025-11-11T10:35:00Z"},
    "111120251040": {"current": 1.67, "power": 30.0, "temperature": 21.2, "voltage": 18.0, "timestamp_human": "2025-11-11T10:40:00Z"},
    "111120251045": {"current": 1.81, "power": 32.5, "temperature": 21.6, "voltage": 18.0, "timestamp_human": "2025-11-11T10:45:00Z"},
    "111120251050": {"current": 1.94, "power": 35.0, "temperature": 22.0, "voltage": 18.0, "timestamp_human": "2025-11-11T10:50:00Z"},
    "111120251055": {"current": 2.08, "power": 37.5, "temperature": 22.4, "voltage": 18.0, "timestamp_human": "2025-11-11T10:55:00Z"},
    "111120251100": {"current": 2.22, "power": 40.0, "temperature": 22.8, "voltage": 18.0, "timestamp_human": "2025-11-11T11:00:00Z"},
    "111120251105": {"current": 2.36, "power": 42.5, "temperature": 23.2, "voltage": 18.0, "timestamp_human": "2025-11-11T11:05:00Z"},
    "111120251110": {"current": 2.50, "power": 45.0, "temperature": 23.6, "voltage": 18.0, "timestamp_human": "2025-11-11T11:10:00Z"},
    "111120251115": {"current": 2.64, "power": 47.5, "temperature": 24.0, "voltage": 18.0, "timestamp_human": "2025-11-11T11:15:00Z"},
    "111120251120": {"current": 2.78, "power": 50.0, "temperature": 24.4, "voltage": 18.0, "timestamp_human": "2025-11-11T11:20:00Z"},
    "111120251125": {"current": 2.92, "power": 52.5, "temperature": 24.8, "voltage": 18.0, "timestamp_human": "2025-11-11T11:25:00Z"},
    "111120251130": {"current": 3.06, "power": 55.0, "temperature": 25.2, "voltage": 18.0, "timestamp_human": "2025-11-11T11:30:00Z"},
    "111120251135": {"current": 3.19, "power": 57.5, "temperature": 25.6, "voltage": 18.0, "timestamp_human": "2025-11-11T11:35:00Z"},
    "111120251140": {"current": 3.33, "power": 60.0, "temperature": 26.0, "voltage": 18.0, "timestamp_human": "2025-11-11T11:40:00Z"},
    "111120251145": {"current": 3.47, "power": 62.5, "temperature": 26.4, "voltage": 18.0, "timestamp_human": "2025-11-11T11:45:00Z"},
    "111120251150": {"current": 3.61, "power": 65.0, "temperature": 26.8, "voltage": 18.0, "timestamp_human": "2025-11-11T11:50:00Z"},
    "111120251155": {"current": 3.75, "power": 67.5, "temperature": 27.2, "voltage": 18.0, "timestamp_human": "2025-11-11T11:55:00Z"},
    "111120251200": {"current": 3.89, "power": 70.0, "temperature": 27.6, "voltage": 18.0, "timestamp_human": "2025-11-11T12:00:00Z"},
    "111120251205": {"current": 4.03, "power": 72.5, "temperature": 28.0, "voltage": 18.0, "timestamp_human": "2025-11-11T12:05:00Z"},
    "111120251210": {"current": 4.17, "power": 75.0, "temperature": 28.4, "voltage": 18.0, "timestamp_human": "2025-11-11T12:10:00Z"},
    "111120251215": {"current": 4.31, "power": 77.5, "temperature": 28.8, "voltage": 18.0, "timestamp_human": "2025-11-11T12:15:00Z"},
    "111120251220": {"current": 4.44, "power": 80.0, "temperature": 29.2, "voltage": 18.0, "timestamp_human": "2025-11-11T12:20:00Z"},
    "111120251225": {"current": 4.58, "power": 82.5, "temperature": 29.6, "voltage": 18.0, "timestamp_human": "2025-11-11T12:25:00Z"},
    "111120251230": {"current": 4.72, "power": 85.0, "temperature": 30.0, "voltage": 18.0, "timestamp_human": "2025-11-11T12:30:00Z"},
    "111120251235": {"current": 4.86, "power": 87.5, "temperature": 30.4, "voltage": 18.0, "timestamp_human": "2025-11-11T12:35:00Z"},
    "111120251300": {"current": 5.00, "power": 90.0, "temperature": 30.8, "voltage": 18.0, "timestamp_human": "2025-11-11T13:00:00Z"},
    "111120251305": {"current": 5.14, "power": 92.5, "temperature": 31.2, "voltage": 18.0, "timestamp_human": "2025-11-11T13:05:00Z"},
    "111120251310": {"current": 5.28, "power": 95.0, "temperature": 31.6, "voltage": 18.0, "timestamp_human": "2025-11-11T13:10:00Z"},
    "111120251315": {"current": 5.42, "power": 97.5, "temperature": 32.0, "voltage": 18.0, "timestamp_human": "2025-11-11T13:15:00Z"},
    "111120251320": {"current": 5.56, "power": 100.0, "temperature": 33.0, "voltage": 18.0, "timestamp_human": "2025-11-11T13:20:00Z"},
    "111120251325": {"current": 5.43, "power": 97.8, "temperature": 32.9, "voltage": 18.0, "timestamp_human": "2025-11-11T13:25:00Z"},
    "111120251330": {"current": 5.31, "power": 95.6, "temperature": 32.8, "voltage": 18.0, "timestamp_human": "2025-11-11T13:30:00Z"},
    "111120251335": {"current": 5.19, "power": 93.3, "temperature": 32.7, "voltage": 18.0, "timestamp_human": "2025-11-11T13:35:00Z"},
    "111120251340": {"current": 5.06, "power": 91.1, "temperature": 32.6, "voltage": 18.0, "timestamp_human": "2025-11-11T13:40:00Z"},
    "111120251345": {"current": 4.94, "power": 88.9, "temperature": 32.5, "voltage": 18.0, "timestamp_human": "2025-11-11T13:45:00Z"},
    "111120251350": {"current": 4.82, "power": 86.7, "temperature": 32.4, "voltage": 18.0, "timestamp_human": "2025-11-11T13:50:00Z"},
    "111120251355": {"current": 4.69, "power": 84.4, "temperature": 32.3, "voltage": 18.0, "timestamp_human": "2025-11-11T13:55:00Z"},
    "111120251400": {"current": 4.57, "power": 82.2, "temperature": 32.2, "voltage": 18.0, "timestamp_human": "2025-11-11T14:00:00Z"},
    "111120251405": {"current": 4.44, "power": 80.0, "temperature": 32.1, "voltage": 18.0, "timestamp_human": "2025-11-11T14:05:00Z"},
    "111120251410": {"current": 4.32, "power": 77.8, "temperature": 32.0, "voltage": 18.0, "timestamp_human": "2025-11-11T14:10:00Z"},
    "111120251415": {"current": 4.20, "power": 75.6, "temperature": 31.9, "voltage": 18.0, "timestamp_human": "2025-11-11T14:15:00Z"},
    "111120251420": {"current": 4.07, "power": 73.3, "temperature": 31.8, "voltage": 18.0, "timestamp_human": "2025-11-11T14:20:00Z"},
    "111120251425": {"current": 3.95, "power": 71.1, "temperature": 31.7, "voltage": 18.0, "timestamp_human": "2025-11-11T14:25:00Z"},
    "111120251430": {"current": 3.83, "power": 68.9, "temperature": 31.6, "voltage": 18.0, "timestamp_human": "2025-11-11T14:30:00Z"},
    "111120251435": {"current": 3.70, "power": 66.7, "temperature": 31.5, "voltage": 18.0, "timestamp_human": "2025-11-11T14:35:00Z"},
    "111120251440": {"current": 3.58, "power": 64.4, "temperature": 31.4, "voltage": 18.0, "timestamp_human": "2025-11-11T14:40:00Z"},
    "111120251445": {"current": 3.46, "power": 62.2, "temperature": 31.3, "voltage": 18.0, "timestamp_human": "2025-11-11T14:45:00Z"},
    "111120251450": {"current": 3.33, "power": 60.0, "temperature": 31.2, "voltage": 18.0, "timestamp_human": "2025-11-11T14:50:00Z"},
    "111120251455": {"current": 3.21, "power": 57.8, "temperature": 31.1, "voltage": 18.0, "timestamp_human": "2025-11-11T14:55:00Z"},
    "111120251500": {"current": 3.09, "power": 55.6, "temperature": 31.0, "voltage": 18.0, "timestamp_human": "2025-11-11T15:00:00Z"},
    "111120251505": {"current": 2.96, "power": 53.3, "temperature": 30.9, "voltage": 18.0, "timestamp_human": "2025-11-11T15:05:00Z"},
    "111120251510": {"current": 2.84, "power": 51.1, "temperature": 30.8, "voltage": 18.0, "timestamp_human": "2025-11-11T15:10:00Z"},
    "111120251515": {"current": 2.72, "power": 48.9, "temperature": 30.7, "voltage": 18.0, "timestamp_human": "2025-11-11T15:15:00Z"},
    "111120251520": {"current": 2.59, "power": 46.7, "temperature": 30.6, "voltage": 18.0, "timestamp_human": "2025-11-11T15:20:00Z"},
    "111120251525": {"current": 2.47, "power": 44.4, "temperature": 30.5, "voltage": 18.0, "timestamp_human": "2025-11-11T15:25:00Z"},
    "111120251530": {"current": 2.35, "power": 42.2, "temperature": 30.4, "voltage": 18.0, "timestamp_human": "2025-11-11T15:30:00Z"},
    "111120251535": {"current": 2.22, "power": 40.0, "temperature": 30.3, "voltage": 18.0, "timestamp_human": "2025-11-11T15:35:00Z"},
    "111120251540": {"current": 2.10, "power": 37.8, "temperature": 30.2, "voltage": 18.0, "timestamp_human": "2025-11-11T15:40:00Z"},
    "111120251545": {"current": 1.98, "power": 35.6, "temperature": 30.1, "voltage": 18.0, "timestamp_human": "2025-11-11T15:45:00Z"},
    "111120251550": {"current": 1.85, "power": 33.3, "temperature": 30.0, "voltage": 18.0, "timestamp_human": "2025-11-11T15:50:00Z"},
    "111120251555": {"current": 1.73, "power": 31.1, "temperature": 29.9, "voltage": 18.0, "timestamp_human": "2025-11-11T15:55:00Z"},
  },
  "sensorData": {
    "battery_temp": 70,
    "motion": false,
    "humanActivity": false,
  },
  "settings": {
    "batteryCapacityMax": 24,
    "darkMode": true,
    "nightLightPref": 0,
    "panelSpecW": 100,
  },
};