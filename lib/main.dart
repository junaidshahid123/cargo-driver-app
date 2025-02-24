import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';
import 'package:cargo_driver_app/api/auth_repo.dart';
import 'package:cargo_driver_app/firebase_options.dart';
import 'package:cargo_driver_app/splash_screen.dart';
import 'package:cargo_driver_app/welcome_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:get/get_connect/http/src/utils/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api/auth_controller.dart';
import 'bindings/contorller_binding.dart';
import 'fcm_handle.dart';
import 'home/chat/chat_page.dart';
import 'home/confirm_location_screen.dart';
import 'home/driver_request_notification_screen.dart';
import 'home/find_trip_online.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'localization_service.dart';
import 'localized_translations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Initialize Firebase if necessary

  debugPrint('Handling a background message: ${message.messageId}');

  // Check if the message contains a notification
  if (message.notification != null) {
    RemoteNotification? notification = message.notification;

    // Print the original notification title and body
    debugPrint('Notification title: ${notification?.title}');
    debugPrint('Notification body: ${notification?.body}');
    print('Notification Title: ${notification?.title}');
    print('Notification Body: ${notification?.body}');

    // Translate title and body to Arabic
    String translatedTitle = _translateToArabic(notification?.title ?? '');
    String translatedBody = _translateToArabic(notification?.body ?? '');

    // Print the translated title and body
    print('Translated Title: $translatedTitle');
    print('Translated Body: $translatedBody');
  } else {
    debugPrint('Notification is null');
  }

  // Check if the message contains data
  if (message.data.isNotEmpty) {
    debugPrint('Message data: ${message.data}');
    print('Message Data: ${message.data}');
  } else {
    debugPrint('Message data is empty');
  }
}

String _translateToArabic(String text) {
  Map<String, String> translations = {
    "new request": "طلب جديد",
    "a new request created in this region. click here":
        "تم إنشاء طلب جديد في هذه المنطقة. انقر هنا",
  };

  // Normalize the input text
  text = text.toLowerCase().trim();

  if (translations.containsKey(text)) {
    return translations[text]!;
  }
  return text; // Return the original text if no translation exists
}

setPreferencesForParcelCollected() async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString('isStart', '0');
  await prefs.setString('isEnd', '0');
  await prefs.setString('isProceed', '0');
}

setPreferencesForProceed() async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString('isProceed', '1');
  await prefs.setString('isStart', '1');
  await prefs.setString('isEnd', '0');
  print(
      'Foreground: prefs.getString(isStart)====${prefs.getString('isStart')}');
  print('Foreground: prefs.getString(isEnd)====${prefs.getString('isEnd')}');
  print(
      'Foreground: prefs.getString(isProceed)====${prefs.getString('isProceed')}');
}

Position? position; // Declare as nullable
RxBool receivedReq = false.obs;
String? fcmToken;
var address = Rx<String>('');
var latitude = Rx<double>(0.0);
var longitude = Rx<double>(0.0);

Future<String?> getFCMToken() async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  try {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      if (Platform.isIOS) {
        String? apnsToken = await messaging.getAPNSToken();
        await prefs.setString('fcm_token', fcmToken ?? '');
        fcmToken = apnsToken;
        print('APNs Token: $apnsToken');
        return fcmToken;
      } else {
        String? token = await messaging.getToken();
        fcmToken = token;
        await prefs.setString('fcm_token', fcmToken ?? '');
        print('FCM Token: $token');
      }
    } else {
      print('Notification permissions not granted');
    }
  } catch (e) {
    print('Error fetching token: $e');
  }
  return fcmToken; // Return the FCM token
}

final _firebaseMessaging = FirebaseMessaging.instance;

Future<void> initNotifications() async {
  await _firebaseMessaging.requestPermission(
    alert: true,
  );
  // final fcmToken = await _firebaseMessaging.getToken();
  print('token=====$fcmToken');
}

Future<void> runInBackground() async {
  await initializeService();
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  /// OPTIONAL, using custom notification channel id
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground', // id
    'MY FOREGROUND SERVICE', // title
    description: 'This channel is used for important notifications.',
    importance: Importance.low, // importance must be at low or higher level
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Initialize notifications for iOS or Android
  if (Platform.isIOS || Platform.isAndroid) {
    await flutterLocalNotificationsPlugin.initialize(
      const InitializationSettings(
        iOS: DarwinInitializationSettings(),
        android: AndroidInitializationSettings('ic_bg_service_small'),
      ),
    );
  }

  // Create the notification channel
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  // Configure the background service
  try {
    // Request permissions explicitly
    PermissionStatus backgroundLocationPermission =
        await Permission.locationAlways.request();

    if (backgroundLocationPermission.isGranted) {
      await service.configure(
        androidConfiguration: AndroidConfiguration(
          // This will be executed when the app is in the foreground or background in a separated isolate
          onStart: onStart,

          // Auto start service
          autoStart: true,
          isForegroundMode: true,

          // Customize the notification
          notificationChannelId: 'my_foreground',
          initialNotificationTitle: 'AWESOME SERVICE',
          initialNotificationContent: 'Initializing...',
          foregroundServiceNotificationId: 888,
          foregroundServiceTypes: [
            AndroidForegroundType.location,
            AndroidForegroundType.dataSync,
          ],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: true,
          onForeground: onStart,
          onBackground: onIosBackground,
        ),
      );
    }
    // Start the service
    service.startService();
  } catch (e) {
    print("Error initializing service: $e");
  }
}

// Future<void> initializeService() async {
//   final service = FlutterBackgroundService();
//
//   /// OPTIONAL, using custom notification channel id
//   const AndroidNotificationChannel channel = AndroidNotificationChannel(
//     'my_foreground', // id
//     'MY FOREGROUND SERVICE', // title
//     description: 'This channel is used for important notifications.',
//     // description
//     importance: Importance.low, // importance must be at low or higher level
//   );
//
//   final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
//       FlutterLocalNotificationsPlugin();
//
//   if (Platform.isIOS || Platform.isAndroid) {
//     await flutterLocalNotificationsPlugin.initialize(
//       const InitializationSettings(
//         iOS: DarwinInitializationSettings(),
//         android: AndroidInitializationSettings('ic_bg_service_small'),
//       ),
//     );
//   }
//
//   await flutterLocalNotificationsPlugin
//       .resolvePlatformSpecificImplementation<
//           AndroidFlutterLocalNotificationsPlugin>()
//       ?.createNotificationChannel(channel);
//
//   await service.configure(
//     androidConfiguration: AndroidConfiguration(
//       // This will be executed when the app is in the foreground or background in a separated isolate
//       onStart: onStart,
//
//       // Auto start service
//       autoStart: true,
//       isForegroundMode: true,
//
//       // Uncomment these lines to customize the notification
//       notificationChannelId: 'my_foreground',
//       initialNotificationTitle: 'AWESOME SERVICE',
//       initialNotificationContent: 'Initializing',
//       foregroundServiceNotificationId: 888,
//       foregroundServiceTypes:  [
//         AndroidForegroundType.location,
//         AndroidForegroundType.dataSync,
//       ], // Correctly using a list of types // This might be correct for your package version
//     ),
//
//
//     iosConfiguration: IosConfiguration(
//       // Auto start service
//       autoStart: true,
//
//       // This will be executed when the app is in the foreground in a separated isolate
//       onForeground: onStart,
//
//       // You have to enable background fetch capability in the Xcode project
//       onBackground: onIosBackground,
//     ),
//   );
//
//   service.startService();
// }

// Future<void> initializeService() async {
//   final service = FlutterBackgroundService();
//
//   /// OPTIONAL, using custom notification channel id
//   const AndroidNotificationChannel channel = AndroidNotificationChannel(
//     'my_foreground', // id
//     'MY FOREGROUND SERVICE', // title
//     description:
//         'This channel is used for important notifications.', // description
//     importance: Importance.low, // importance must be at low or higher level
//   );
//
//   final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
//       FlutterLocalNotificationsPlugin();
//
//   if (Platform.isIOS || Platform.isAndroid) {
//     await flutterLocalNotificationsPlugin.initialize(
//       const InitializationSettings(
//         iOS: DarwinInitializationSettings(),
//         android: AndroidInitializationSettings('ic_bg_service_small'),
//       ),
//     );
//   }
//
//   await flutterLocalNotificationsPlugin
//       .resolvePlatformSpecificImplementation<
//           AndroidFlutterLocalNotificationsPlugin>()
//       ?.createNotificationChannel(channel);
//
//   await service.configure(
//     androidConfiguration: AndroidConfiguration(
//       // this will be executed when app is in foreground or background in separated isolate
//       onStart: onStart,
//
//       // auto start service
//       autoStart: true,
//       isForegroundMode: true,
//
//       // notificationChannelId: 'my_foreground',
//       // initialNotificationTitle: 'AWESOME SERVICE',
//       // initialNotificationContent: 'Initializing',
//       // foregroundServiceNotificationId: 888,
//     ),
//     iosConfiguration: IosConfiguration(
//       // auto start service
//       autoStart: true,
//
//       // this will be executed when app is in foreground in separated isolate
//       onForeground: onStart,
//
//       // you have to enable background fetch capability on xcode project
//       onBackground: onIosBackground,
//     ),
//   );
// }

// to ensure this is executed
// run app from xcode, then from xcode menu, select Simulate Background Fetch

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.reload();
  final log = preferences.getStringList('log') ?? <String>[];
  log.add(DateTime.now().toIso8601String());
  await preferences.setStringList('log', log);

  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Initialize SharedPreferences and AuthRepo
  final SharedPreferences sharedPreferences =
      await SharedPreferences.getInstance();

  final AuthRepo authRepo = AuthRepo(sharedPreferences: sharedPreferences);

  // Register AuthController with GetX
  if (!Get.isRegistered<AuthController>()) {
    Get.put(AuthController(authRepo: authRepo));
  }

  // Retrieve request_id from SharedPreferences
  String? requestId = sharedPreferences.getString('request_id');
  print('Retrieved request_id: $requestId');

  // Save a test value in SharedPreferences
  SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setString("hello", "world");

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  if (service is AndroidServiceInstance) {
    // Set the service as a foreground service and display the initial notification
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: "My App Service",
      content: "Fetching location periodically",
    );

    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  Timer.periodic(const Duration(minutes: 15), (timer) async {
    print('FLUTTER BACKGROUND SERVICE: ${DateTime.now()}');

    // Ensure the service is running in the foreground
    if (service is AndroidServiceInstance &&
        !await service.isForegroundService()) {
      print('Service is not in foreground, stopping task execution');
      return;
    }

    // Retrieve the updated values for isStart and isEnd
    sharedPreferences.reload(); // Ensure you reload the preferences
    String? isStart = sharedPreferences.getString('isStart');
    String? isEnd = sharedPreferences.getString('isEnd');
    String? isProceed = sharedPreferences.getString('isProceed');
    print(
        'Background: Retrieved isStart: $isStart, isEnd: $isEnd, isProceed: $isProceed');

    try {
      // Obtain the current position
      position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      print(
          'Position obtained: latitude=${position!.latitude}, longitude=${position!.longitude}');
      await createHistory(
          isStart: isStart ?? '',
          isEnd: isEnd ?? '',
          isProceed: isProceed ?? '');
    } catch (e) {
      print('Error obtaining position: $e');
      return;
    }

    final deviceInfo = DeviceInfoPlugin();
    String? device;
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        device = androidInfo.model;
        print('Device info obtained: model=$device');
      }

      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        device = iosInfo.model;
        print('Device info obtained: model=$device');
      }
    } catch (e) {
      print('Error obtaining device info: $e');
    }

    // Invoke the update method with the current data
    service.invoke(
      'update',
      {
        "current_date": DateTime.now().toIso8601String(),
        "device": device,
        "location": {
          "latitude": position!.latitude,
          "longitude": position!.longitude,
        },
      },
    );

    // Display a notification if the service is running in the foreground
    if (service is AndroidServiceInstance &&
        await service.isForegroundService()) {
      flutterLocalNotificationsPlugin.show(
        888,
        'COOL SERVICE',
        'Awesome ${DateTime.now()}',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'my_foreground',
            'MY FOREGROUND SERVICE',
            icon: 'ic_bg_service_small',
            ongoing: true,
          ),
        ),
      );

      service.setForegroundNotificationInfo(
        title: "My App Service",
        content: "Location Fetching Time at ${DateTime.now()}",
      );
    }
  });
}

Future<String> getAddress(double latitude, double longitude) async {
  try {
    List<Placemark> places =
        await placemarkFromCoordinates(latitude, longitude);
    Placemark place = places.first;
    address.value = 'Address: ${place.locality}, ${place.country}';
  } catch (e) {
    print('Error occurred while getting address: $e');
  }
  return address.value;
}

// Function to retrieve the request_id from SharedPreferences
Future<String?> getRequestId() async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  // Retrieve request_id from SharedPreferences
  return prefs.getString('request_id');
}

Future<bool> createHistory(
    {required String isStart,
    required String isEnd,
    required String isProceed}) async {
  position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high);
  print('position==$position');
  address.value = await getAddress(position!.latitude, position!.longitude);
  SharedPreferences prefs = await SharedPreferences.getInstance();
  String? requestId = prefs.getString('request_id');
  final url = Uri.parse('https://thardi.com/api/createHistory');
  final headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    "Authorization":
        "Bearer ${Get.find<AuthController>().authRepo.getAuthToken()}"
  };
  final body = jsonEncode({
    'request_id': requestId,
    'lat': position!.latitude,
    'long': position!.longitude,
    'address': address.value,
    'is_start': isStart,
    'is_end': isEnd,
    'is_proceed': isProceed,
  });
  print(
      'Get.find<AuthController>().authRepo.getAuthToken()======${Get.find<AuthController>().authRepo.getAuthToken()}');
  print('body=$body');

  try {
    final response = await http.post(url, headers: headers, body: body);

    if (response.statusCode == 200) {
      // Successfully created history
      print('Successful to create history In Background');
      print('Response body: ${response.body}');

      return true;
      // isRideStarted.value = true;
      // _startPeriodicHistoryUpdates();
    } else {
      // Error creating history
      print('Failed to create history. Status code: ${response.statusCode}');
      print('Response body: ${response.body}');
      return false;
    }
  } catch (e) {
    // Exception handling
    print('Exception caught: $e');

    return false;
  }
}

void startBackgroundService() {
  const platform = MethodChannel('com.tarudDriver.app/background_service');
  platform.invokeMethod('startService').then((value) {
    // Handle success case
    print('Background service started successfully');
    print('value=========$value');
  }).catchError((e) {
    // Handle error case
    print('Error starting background service: $e');
  });
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

void changeLanguage(String languageCode) {
  // Set the new language locale
  if (languageCode == "en") {
    LocalizationService.changeLocale(const Locale('en'));
  } else if (languageCode == "ar") {
    LocalizationService.changeLocale(const Locale('ar'));
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides();
  // Initialize Firebase
  // Initialize Firebase
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }

  await getFCMToken();
  await initNotifications();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  // Initialize and start the background service
  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );
  // requestLocationPermission();
  await initializeService();

  runApp(const CargoDeleiveryApp());
}

Future<void> requestLocationPermission() async {
  PermissionStatus status = await Permission.location.request();
  if (status.isGranted) {
    // Permission granted, start your foreground service
    // initializeService();
    runInBackground();
  } else {
    // Handle permission denial
    print("Location permission denied");
  }
}

class CargoDeleiveryApp extends StatefulWidget {
  const CargoDeleiveryApp({super.key});

  @override
  State<CargoDeleiveryApp> createState() => _CargoDeleiveryAppState();
}

class _CargoDeleiveryAppState extends State<CargoDeleiveryApp>
    with WidgetsBindingObserver {
  final _messagingService = MessagingService();
  RemoteMessage? _initialMessage;
  bool _isSplashDone = false;

  @override
  void initState() {
    _messagingService.init(context);
    super.initState();
    _setupInteractedMessage();
    WidgetsBinding.instance
        .addObserver(this); // Add observer for lifecycle changes
  }

  @override
  void dispose() {
    WidgetsBinding.instance
        .removeObserver(this); // Remove observer to prevent memory leaks
    super.dispose();
  }

  // void didChangeAppLifecycleState(AppLifecycleState state) {
  //   if (state == AppLifecycleState.paused) {
  //     FlutterBackgroundService().startService();
  //   } else if (state == AppLifecycleState.resumed) {
  //     FlutterBackgroundService().invoke('stopService');
  //     printStoredLogs();
  //   }
  // }

  Future<void> printStoredLogs() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? lastRequestUrl = prefs.getString('last_request_url');
    String? lastRequestHeaders = prefs.getString('last_request_headers');
    String? lastRequestBody = prefs.getString('last_request_body');
    int? lastResponseStatusCode = prefs.getInt('last_response_status_code');
    String? lastResponseBody = prefs.getString('last_response_body');
    String? lastRequestException = prefs.getString('last_request_exception');

    print('Last Request URL: $lastRequestUrl');
    print('Last Request Headers: $lastRequestHeaders');
    print('Last Request Body: $lastRequestBody');
    print('Last Response Status Code: $lastResponseStatusCode');
    print('Last Response Body: $lastResponseBody');
  }

  void _setupInteractedMessage() async {
    // Get the initial message
    _initialMessage = await FirebaseMessaging.instance.getInitialMessage();

    // If the initial message is not null, it means the app was opened via a notification
    if (_initialMessage != null) {
      _navigateToInitialRoute();
    }

    // Handle interaction when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _handleMessage(message);
    });
  }

  Future<void> _handleMessage(RemoteMessage message) async {
    // Navigate to the desired screen with the message data
    if (message.notification?.title == 'New request') {
      Get.to(() => FindTripOnline(message: message));
    } else if (message.notification?.title == 'Accept Offer') {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool('acceptOffer', true);
      await prefs.setString('isStart', '1');
      await prefs.setString('isEnd', '0');
      Get.offAll(() => DriverRequestNotificationScreen(message: message));
    } else if (message.notification?.title == 'New Message') {
      Get.to(() => ChatPage(message: message));
    }
  }

  void _navigateToInitialRoute() {
    if (_isSplashDone && _initialMessage != null) {
      _handleMessage(_initialMessage!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(375, 812),
      minTextAdapt: true,
      builder: (_, child) {
        return GetMaterialApp(
          translations: LocalizedTranslations(),
          // Use the wrapper class
          locale: Get.deviceLocale,
          // Set the default locale
          fallbackLocale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('ar')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          initialBinding: Binding(),
          themeMode: ThemeMode.light,
          theme: ThemeData(
            fontFamily: 'RadioCanada',
          ),
          debugShowCheckedModeBanner: false,
          title: 'Cargo App',
          home: SplashScreen(
            onInitializationComplete: () async {
              _isSplashDone = true;
              _navigateToInitialRoute();
              SharedPreferences prefs = await SharedPreferences.getInstance();
              bool acceptOffer = prefs.getBool('acceptOffer') ?? false;
              bool hasBidAndWaiting =
                  prefs.getBool('hasBidAndWaiting') ?? false;

              if (acceptOffer || hasBidAndWaiting) {
                Get.offAll(() =>
                    DriverRequestNotificationScreen(message: _initialMessage));
              } else {
                if (_initialMessage == null) {
                  Get.offAll(() => Get.find<AuthController>().isLogedIn()
                      ? LocationPage()
                      : const WelcomeScreen());
                }
              }
            },
          ),
          getPages: [
            GetPage(
                name: '/',
                page: () => SplashScreen(onInitializationComplete: () {})),
            GetPage(
                name: '/findTrip',
                page: () => FindTripOnline(message: _initialMessage)),
            GetPage(
                name: '/driverRequest',
                page: () =>
                    DriverRequestNotificationScreen(message: _initialMessage)),
            GetPage(
                name: '/chatPage',
                page: () => ChatPage(message: _initialMessage)),
          ],
        );
      },
    );
  }
}
