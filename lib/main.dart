import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// UniWear – Flutter client backed by Supabase. Prices are seeded from the photographed audit.
bool _uniwearDark = false;
Color get navy => _uniwearDark ? const Color(0xFFB6CEE8) : const Color(0xFF1C3447);
Color get actionText => _uniwearDark ? const Color(0xFF112838) : Colors.white;
const heroNavy = Color(0xFF1C3447);
const navyDeep = Color(0xFF112838);
Color get gold => _uniwearDark ? const Color(0xFFE2BC86) : const Color(0xFFC5A071);
Color get cream => _uniwearDark ? const Color(0xFF111A24) : const Color(0xFFFAF8F5);
Color get warm => _uniwearDark ? const Color(0xFF263340) : const Color(0xFFF2EFEB);
Color get textDark => _uniwearDark ? const Color(0xFFF0F3F6) : const Color(0xFF21303A);
Color get textMuted => _uniwearDark ? const Color(0xFFB0BBC7) : const Color(0xFF737D83);
Color get stroke => _uniwearDark ? const Color(0xFF34424F) : const Color(0xFFECE8E3);
Color get white => _uniwearDark ? const Color(0xFF1C2834) : Colors.white;

String money(int amount) {
  final source = amount.toString();
  final output = StringBuffer();
  for (var i = 0; i < source.length; i++) {
    if (i > 0 && (source.length - i) % 3 == 0) output.write(',');
    output.write(source[i]);
  }
  return '₱${output.toString()}';
}

class UniformProduct {
  const UniformProduct({required this.id, required this.name, required this.section,
    required this.group, required this.prices, required this.image,
    required this.description, this.sources = const [], this.illustration = false,
    this.needsVerification = false});
  final String id, name, section, group, image, description;
  final Map<String, int> prices;
  final List<int> sources; // Uploaded IMG_0NNN reference numbers
  final bool illustration, needsVerification;
  bool get canOrder => prices.isNotEmpty;
  int? get startingPrice => prices.isEmpty ? null : prices.values.reduce((a, b) => a < b ? a : b);
}

// Maps are size -> PHP price, exactly as visible in IMG_0543 and IMG_0544.
List<UniformProduct> catalog = <UniformProduct>[];

UniformProduct productOf(String id) => catalog.firstWhere((p) => p.id == id);

const Map<String, List<int>> _productSources = {
  'shs-f-vest': [536], 'shs-m-vest': [530], 'hs-blouse': [532],
  'neu-skirt': [538], 'neu-pants': [528], 'female-tie': [536],
  'junior-tie': [530], 'college-polo': [527], 'college-pants': [528],
  'college-skirt': [534], 'integrated-pe-shirt': [539],
  'integrated-pe-pants': [540],
};

class CartItem {
  CartItem(this.id, this.size, this.quantity);
  final String id, size;
  int quantity;
  int get unit => productOf(id).prices[size] ?? 0;
  int get total => quantity * unit;
  Map<String, dynamic> toJson() => {'productId':id,'size':size,'quantity':quantity};
  factory CartItem.fromJson(Map<String, dynamic> data) => CartItem(
    data['productId'] as String,data['size'] as String,data['quantity'] as int);
}


class AppStore extends ChangeNotifier {
  AppStore();
  final List<CartItem> cart = [];
  final List<Map<String, dynamic>> orders = [];
  List<Map<String, dynamic>> adminOrders = [];
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  bool loaded = false;
  bool hasSeenIntro = false;
  bool signedIn = false;
  bool darkMode = false;
  bool isAdmin = false;
  bool busy = false;
  String? errorMessage;
  Map<String, dynamic> profile = {};

  SupabaseClient get _client => Supabase.instance.client;

  Future<void> load() async {
    darkMode = await _prefs.getBool('uniwearDarkMode') ?? false;
    hasSeenIntro = await _prefs.getBool('uniwearSeenIntro') ?? false;
    _uniwearDark = darkMode;
    signedIn = _client.auth.currentSession != null;
    final cartData = jsonDecode(await _prefs.getString('uniformCart') ?? '[]') as List;
    cart
      ..clear()
      ..addAll(cartData.map((e) => CartItem.fromJson(Map<String, dynamic>.from(e as Map))));
    if (signedIn) {
      try {
        await loadBackendData();
      } catch (error) {
        errorMessage = _friendlyError(error);
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> loadBackendData() async {
    errorMessage = null;
    await refreshProfile();
    await loadCatalog();
    await refreshOrders();
    if (isAdmin) await refreshAdminOrders();
  }

  Future<void> refreshProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('Your session has expired. Please sign in again.');
    final row = await _client.from('profiles').select(
      'id, full_name, student_number, role, created_at',
    ).eq('id', user.id).single();
    profile = Map<String, dynamic>.from(row);
    isAdmin = profile['role'] == 'admin';
  }

  Future<void> loadCatalog() async {
    final productRows = await _client.from('products').select(
      'id, name, section, grp, image, description, needs_verification, active, sort_order',
    ).eq('active', true).order('sort_order', ascending: true);
    final priceRows = await _client.from('product_prices').select(
      'product_id, size, price_php, sort_order',
    ).order('sort_order', ascending: true);

    final pricesByProduct = <String, Map<String, int>>{};
    for (final row in priceRows) {
      final id = row['product_id'] as String;
      pricesByProduct.putIfAbsent(id, () => <String, int>{})[row['size'] as String] =
          row['price_php'] as int;
    }

    catalog = productRows.map<UniformProduct>((row) {
      final id = row['id'] as String;
      final image = row['image'] as String;
      return UniformProduct(
        id: id,
        name: row['name'] as String,
        section: row['section'] as String,
        group: row['grp'] as String,
        image: image,
        description: row['description'] as String,
        prices: pricesByProduct[id] ?? const <String, int>{},
        sources: _productSources[id] ?? const <int>[],
        illustration: image.contains('illustration'),
        needsVerification: row['needs_verification'] as bool? ?? false,
      );
    }).toList(growable: false);

    cart.removeWhere((item) => !catalog.any((product) =>
      product.id == item.id && product.prices.containsKey(item.size)));
    await _persistCart();
  }

  Future<void> refreshOrders() async {
    final rows = await _client.from('orders').select(
      'id, order_number, status, total_php, created_at, '
      'order_items(id, product_id, size, quantity, unit_price_php, product_name)',
    ).order('created_at', ascending: false);
    orders
      ..clear()
      ..addAll(rows.map((row) => Map<String, dynamic>.from(row)));
  }

  Future<void> refreshAdminOrders() async {
    if (!isAdmin) {
      adminOrders = [];
      return;
    }
    final result = await _client.rpc('admin_list_orders');
    adminOrders = (result as List).map((row) =>
      Map<String, dynamic>.from(row as Map)).toList();
  }

  Future<void> signIn(String email, String password) async {
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await _client.auth.signInWithPassword(email: email.trim(), password: password);
      signedIn = true;
      await loadBackendData();
    } catch (error) {
      errorMessage = _friendlyError(error);
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> signUp({
    required String fullName,
    required String studentNumber,
    required String email,
    required String password,
  }) async {
    final response = await _client.auth.signUp(
      email: email.trim(),
      password: password,
      data: {
        'full_name': fullName.trim(),
        'student_number': studentNumber.trim(),
      },
    );
    if (response.session != null) {
      signedIn = true;
      await loadBackendData();
      notifyListeners();
    }
  }

  Future<void> resetPassword(String email) async {
    await _client.auth.resetPasswordForEmail(email.trim());
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    signedIn = false;
    isAdmin = false;
    profile = {};
    orders.clear();
    adminOrders.clear();
    errorMessage = null;
    notifyListeners();
  }

  void setDarkMode(bool value) {
    darkMode = value;
    _uniwearDark = value;
    _prefs.setBool('uniwearDarkMode', value);
    notifyListeners();
  }

  void finishIntro() {
    hasSeenIntro = true;
    _prefs.setBool('uniwearSeenIntro', true);
    notifyListeners();
  }

  int get count => cart.fold(0, (sum, item) => sum + item.quantity);
  int get total => cart.fold(0, (sum, item) => sum + item.total);

  void add(UniformProduct product, String size, int qty) {
    if (!product.prices.containsKey(size) || qty < 1 || qty > 10) return;
    for (final item in cart) {
      if (item.id == product.id && item.size == size) {
        if (item.quantity + qty > 10) return;
        item.quantity += qty;
        _persistCart();
        notifyListeners();
        return;
      }
    }
    cart.add(CartItem(product.id, size, qty));
    _persistCart();
    notifyListeners();
  }

  void quantity(CartItem item, int delta) {
    final next = item.quantity + delta;
    if (next > 10) return;
    item.quantity = next;
    if (item.quantity <= 0) cart.remove(item);
    _persistCart();
    notifyListeners();
  }

  Future<String> placeOrder() async {
    if (cart.isEmpty) throw StateError('Your cart is empty.');
    final result = await _client.rpc('place_order', params: {
      'items': cart.map((item) => {
        'product_id': item.id,
        'size': item.size,
        'quantity': item.quantity,
      }).toList(),
    });
    final response = Map<String, dynamic>.from(result as Map);
    cart.clear();
    await _persistCart();
    await refreshOrders();
    notifyListeners();
    return response['order_number'] as String;
  }

  Future<bool> cancelPendingOrder(Map<String, dynamic> order) async {
    if (order['status'] != 'Pending') return false;
    await _client.rpc('cancel_order', params: {'order_id': order['id']});
    await refreshOrders();
    notifyListeners();
    return true;
  }

  Future<void> updateOrderStatus(Map<String, dynamic> order, String next) async {
    await _client.rpc('admin_set_status', params: {
      'order_id': order['id'],
      'new_status': next,
    });
    await refreshAdminOrders();
    await refreshOrders();
    notifyListeners();
  }

  Future<void> retry() async {
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      signedIn = _client.auth.currentSession != null;
      if (!signedIn) throw StateError('Please sign in to continue.');
      await loadBackendData();
    } catch (error) {
      errorMessage = _friendlyError(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _persistCart() async {
    await _prefs.setString('uniformCart', jsonEncode(cart.map((item) => item.toJson()).toList()));
  }

  String _friendlyError(Object error) {
    if (error is AuthException) return error.message;
    if (error is PostgrestException) return error.message;
    if (error is TimeoutException) return 'The request timed out. Check your connection and retry.';
    return error.toString().replaceFirst('Exception: ', '');
  }
}

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_supabaseUrl.isEmpty || _supabasePublishableKey.isEmpty) {
    runApp(const SupabaseSetupRequiredApp());
    return;
  }
  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _supabasePublishableKey,
  );
  runApp(const UniWearApp());
}

class SupabaseSetupRequiredApp extends StatelessWidget {
  const SupabaseSetupRequiredApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          BrandLogo(size: 76),
          const SizedBox(height: 18),
          const Text('Connect UniWear to Supabase',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          const Text('Build with --dart-define=SUPABASE_URL=... and '
            '--dart-define=SUPABASE_PUBLISHABLE_KEY=... to load the live catalog and accounts.',
            textAlign: TextAlign.center),
        ]),
      )),
    ),
  );
}

class UniWearApp extends StatefulWidget { const UniWearApp({super.key});
  @override State<UniWearApp> createState()=>_UniWearAppState(); }
class _UniWearAppState extends State<UniWearApp> {
  final store=AppStore();
  @override void initState(){super.initState();store.load();}
  @override void dispose(){store.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:store,builder:(_,__)=>MaterialApp(
    debugShowCheckedModeBanner:false,title:'UniWear',
    themeAnimationDuration:Duration(milliseconds:260),
    themeAnimationCurve:Curves.easeInOutCubic,
    themeMode:store.darkMode ? ThemeMode.dark : ThemeMode.light,
    theme:ThemeData(useMaterial3:true,brightness:store.darkMode ? Brightness.dark : Brightness.light,
      splashFactory:InkRipple.splashFactory,
      scaffoldBackgroundColor:cream,
      colorScheme:ColorScheme.fromSeed(seedColor:navy,
        brightness:store.darkMode ? Brightness.dark : Brightness.light,
        primary:navy,surface:cream),
      textTheme:TextTheme(bodyLarge:TextStyle(color:textDark),bodyMedium:TextStyle(color:textDark)),
      appBarTheme:AppBarTheme(backgroundColor:cream,foregroundColor:navy,
        elevation:0,scrolledUnderElevation:0,titleTextStyle:TextStyle(color:textDark,fontSize:20,fontWeight:FontWeight.w800)),
      pageTransitionsTheme:PageTransitionsTheme(builders:{
        TargetPlatform.iOS:CupertinoPageTransitionsBuilder(),
        TargetPlatform.android:ZoomPageTransitionsBuilder(),
      }),
      cardTheme:CardThemeData(color:white,elevation:0,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(20))),
      filledButtonTheme:FilledButtonThemeData(style:FilledButton.styleFrom(backgroundColor:navy,
        foregroundColor:actionText,minimumSize:const Size(10,54),
        animationDuration:const Duration(milliseconds:160),
        shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(15)))),
      inputDecorationTheme:InputDecorationTheme(filled:true,fillColor:white,
        contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:15),
        border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide(color:stroke)),
        enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide(color:stroke))),
      navigationBarTheme:NavigationBarThemeData(backgroundColor:white,indicatorColor:_uniwearDark ? const Color(0xFF344759) : const Color(0xFFE9E3DC),
        labelTextStyle:WidgetStateProperty.resolveWith((states)=>TextStyle(
          color:states.contains(WidgetState.selected)?navy:textMuted,fontSize:11,fontWeight:FontWeight.w700)))),
    home: !store.loaded
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : store.signedIn && store.errorMessage != null
        ? BackendErrorPage(store: store)
        : store.signedIn
          ? AppShell(store: store)
          : SignInPage(store: store)));
}


class BackendErrorPage extends StatelessWidget {
  const BackendErrorPage({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off_outlined, size: 64),
        const SizedBox(height: 16),
        const Text('UniWear could not reach the backend',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
          textAlign: TextAlign.center),
        const SizedBox(height: 9),
        Text(store.errorMessage ?? 'Check your internet connection and retry.',
          textAlign: TextAlign.center),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: store.busy ? null : store.retry,
          icon: const Icon(Icons.refresh),
          label: Text(store.busy ? 'Retrying…' : 'Retry'),
        ),
        TextButton(onPressed: store.signOut, child: const Text('Sign out')),
      ]),
    )),
  );
}

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key, required this.store});
  final AppStore store;
  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _studentNumber = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _hidden = true;

  @override
  void dispose() {
    _name.dispose();
    _studentNumber.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _loading = true);
    try {
      await widget.store.signUp(
        fullName: _name.text,
        studentNumber: _studentNumber.text,
        email: _email.text,
        password: _password.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Account created. Check your email if confirmation is enabled.'),
      ));
      if (widget.store.signedIn) {
        Navigator.popUntil(context, (route) => route.isFirst);
      } else {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Create student account')),
    body: Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.all(20), children: [
        TextFormField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Full name'),
          validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your full name' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _studentNumber,
          decoration: const InputDecoration(labelText: 'Student number'),
          validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your student number' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email address'),
          validator: (v) => !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim())
            ? 'Enter a valid email address' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _password,
          obscureText: _hidden,
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              onPressed: () => setState(() => _hidden = !_hidden),
              icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            ),
          ),
          validator: (v) => (v ?? '').length < 8 ? 'Use at least 8 characters' : null,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: Text(_loading ? 'Creating account…' : 'Create account'),
        ),
      ]),
    ),
  );
}

class BrandLogo extends StatelessWidget {
  BrandLogo({super.key,this.size=36});final double size;
  @override Widget build(BuildContext context)=>ClipRRect(borderRadius:BorderRadius.circular(size*.23),
    child:Image.asset('assets/brand/uniwear_icon.png',width:size,height:size,fit:BoxFit.cover));
}


/// Supabase email/password sign-in.
class SignInPage extends StatefulWidget {
  const SignInPage({super.key,required this.store});
  final AppStore store;
  @override State<SignInPage> createState()=>_SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _form=GlobalKey<FormState>();
  final _identifier=TextEditingController();
  final _password=TextEditingController();
  bool _hidden=true;
  String? _authError;
  bool _loading=false;
  @override void dispose(){_identifier.dispose();_password.dispose();super.dispose();}

  Future<void> _signIn() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() { _authError = null; _loading = true; });
    try {
      await widget.store.signIn(_identifier.text, _password.text);
    } catch (error) {
      if (mounted) setState(() => _authError = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override Widget build(BuildContext context){
    final palette=Theme.of(context).colorScheme;
    return Scaffold(body:SafeArea(child:ListView(
      padding:EdgeInsets.fromLTRB(22,12,22,25),children:[
      SizedBox(height:8),Text('UniWear',style:TextStyle(fontFamily:'Avenir Next',fontWeight:FontWeight.w900,
          fontSize:30,letterSpacing:-1.0,color:textDark)),
      SizedBox(height:22),ClipRRect(borderRadius:BorderRadius.circular(25),
        child:SizedBox(height:230,child:Stack(fit:StackFit.expand,children:[
          Image.network(
            'https://upload.wikimedia.org/wikipedia/commons/3/31/NEU_Main_Campus%2C_Central_Avenue%2C_New_Era%2C_Quezon_City.jpg',
            fit:BoxFit.cover,
            errorBuilder:(_,__,___)=>Container(
              decoration:BoxDecoration(gradient:LinearGradient(colors:[heroNavy,Color(0xFF48657D)])),
              child:Center(child:Icon(Icons.account_balance_outlined,
                size:82,color:Colors.white.withOpacity(.55))))),
          DecoratedBox(decoration:BoxDecoration(gradient:LinearGradient(
            begin:Alignment.topCenter,end:Alignment.bottomCenter,
            colors:[Colors.transparent,Color(0xD5112838)]))),
          Positioned(left:19,bottom:22,right:15,child:Column(
            crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('New Era University',style:TextStyle(color:Colors.white,fontSize:22,
              fontWeight:FontWeight.w900)),SizedBox(height:4),
            Text('Your campus essentials, one place.',style:TextStyle(color:Colors.white,fontSize:12))
          ])),
          Positioned(top:8,right:8,child:IconButton(
            tooltip:'Campus photo details',
            icon:const Icon(Icons.info_outline_rounded,color:Colors.white,size:19),
            onPressed:_showPhotoCredit)),
        ]))),
      SizedBox(height:21),Text('Welcome back',style:TextStyle(color:textDark,
        fontSize:27,fontWeight:FontWeight.w900,letterSpacing:-0.7)),
      SizedBox(height:5),Text('Sign in to browse uniforms and track your orders.',
        style:TextStyle(color:textMuted,fontSize:12)),
      SizedBox(height:18),Form(key:_form,child:Column(children:[
        TextFormField(controller:_identifier,keyboardType:TextInputType.emailAddress,
          textInputAction:TextInputAction.next,
          decoration:InputDecoration(labelText:'Email address',
            prefixIcon:Icon(Icons.alternate_email_rounded,color:navy)),
          validator:(value){final v=(value??'').trim();
            if (v.isEmpty) return 'Enter your email address';
            if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) {
              return 'Enter a valid email address';
            }
            return null;
          }),
        SizedBox(height:12),TextFormField(controller:_password,
          obscureText:_hidden,textInputAction:TextInputAction.done,
          onFieldSubmitted:(_)=>_signIn(),
          decoration:InputDecoration(labelText:'Password',prefixIcon:Icon(Icons.lock_outline_rounded,color:navy),
            suffixIcon:IconButton(tooltip:_hidden?'Show password':'Hide password',
              icon:Icon(_hidden?Icons.visibility_outlined:Icons.visibility_off_outlined),
              onPressed:()=>setState(()=>_hidden=!_hidden))),
          validator:(v)=>(v??'').length<8?'Enter at least 8 characters':null),
      ])),
      if(_authError != null)Padding(padding:EdgeInsets.only(top:9),child:Text(
        _authError!,
        style:TextStyle(color:palette.error,fontSize:12))),
      Align(alignment:Alignment.centerRight,child:TextButton(
        onPressed:_forgotPassword,child:Text('Forgot password?'))),
      SizedBox(height:7),SizedBox(width:double.infinity,child:FilledButton(
        onPressed:_loading?null:_signIn,
        child:Text(_loading?'Signing in…':'Sign in to UniWear'))),
      SizedBox(height:8),
      TextButton(
        onPressed: _loading ? null : () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => SignUpPage(store: widget.store))),
        child: const Text('Create a student account'),
      ),
    ])));
  }
  void _showPhotoCredit() {
    showDialog<void>(context:context,builder:(dialogContext)=>AlertDialog(
      title:const Text('Campus photograph'),
      content:const SelectableText(
        'NEU Main Campus, Central Avenue, New Era, Quezon City. Photo by ErwinBriones, '
        'Wikimedia Commons, CC BY-SA 4.0.\n'
        'Source: https://commons.wikimedia.org/wiki/File:NEU_Main_Campus,_Central_Avenue,_New_Era,_Quezon_City.jpg\n'
        'License: https://creativecommons.org/licenses/by-sa/4.0/'),
      actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext),child:const Text('Close'))],
    ));
  }
  Future<void> _forgotPassword() async {
    final emailController = TextEditingController(text: _identifier.text.trim());
    final email = await showDialog<String>(context: context, builder: (dialogContext) =>
      AlertDialog(
        title: const Text('Reset password'),
        content: TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email address'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, emailController.text.trim()),
            child: const Text('Send reset email')),
        ],
      ));
    emailController.dispose();
    if (email == null || email.isEmpty || !mounted) return;
    try {
      await widget.store.resetPassword(email);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password reset email sent. Check your inbox.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString()), backgroundColor: Theme.of(context).colorScheme.error));
    }
  }
}

class IntroPage extends StatelessWidget {
  const IntroPage({super.key,required this.store});
  final AppStore store;
  @override Widget build(BuildContext context)=>Scaffold(body:SafeArea(child:Padding(
    padding:const EdgeInsets.fromLTRB(27,20,27,20),child:Column(children:[
      Spacer(),BrandLogo(size:122),SizedBox(height:19),
      Text('UniWear',style:TextStyle(color:navy,fontSize:35,fontWeight:FontWeight.w900,letterSpacing:-1.2)),
      Text('YOUR CAMPUS UNIFORMS, MADE SIMPLE',textAlign:TextAlign.center,
        style:TextStyle(color:textMuted,fontSize:10,letterSpacing:1.3,fontWeight:FontWeight.w700)),
      Spacer(),Container(height:205,width:double.infinity,
        decoration:BoxDecoration(color:warm,borderRadius:BorderRadius.circular(24)),
        child:Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:[
          Expanded(child:Image.asset('assets/products/male_shs_vest.png',fit:BoxFit.contain)),
          Expanded(child:Image.asset('assets/products/college_skirt.png',fit:BoxFit.contain)),
        ])),SizedBox(height:21),Text('Find your school-day essentials',
        textAlign:TextAlign.center,style:TextStyle(fontSize:20,fontWeight:FontWeight.w900,color:textDark)),
      SizedBox(height:8),Text('Browse uniforms, compare sizes and place your campus pickup order — all in one place.',
        textAlign:TextAlign.center,style:TextStyle(fontSize:13,color:textMuted,height:1.5)),
      Spacer(),SizedBox(width:double.infinity,child:FilledButton(
        onPressed:store.finishIntro,child:Text('Explore uniforms'))),
    ]))));
}

class AppShell extends StatefulWidget {const AppShell({super.key,required this.store});final AppStore store;
  @override State<AppShell> createState()=>_AppShellState();}
class _AppShellState extends State<AppShell> {
  int index=0;
  String shopSection='All';
  final PageController _pageController=PageController();
  @override void dispose(){_pageController.dispose();super.dispose();}
  void _animateToTab(int tab) {
    if (index != tab) setState(()=>index=tab);
    _pageController.animateToPage(tab,
      duration:const Duration(milliseconds:450),curve:Curves.easeInOutCubic);
  }
  void goShop([String value='All']) {
    setState(()=>shopSection=value);
    _animateToTab(1); // Slide naturally to the shop when tapping "Shop now".
  }
  @override Widget build(BuildContext context){
    final pages=[HomePage(store:widget.store,onShop:goShop),
      ShopPage(key:ValueKey(shopSection),store:widget.store,initialSection:shopSection),
      OrdersPage(store:widget.store),SettingsPage(store:widget.store)];
    return Scaffold(body:SafeArea(child:PageView(
      controller:_pageController,physics:const NeverScrollableScrollPhysics(),
      onPageChanged:(page){if(index!=page)setState(()=>index=page);},
      children:pages)),
      bottomNavigationBar:NavigationBar(selectedIndex:index,height:72,
        onDestinationSelected:_animateToTab,destinations:[
          NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home_rounded),label:'Home'),
          NavigationDestination(icon:Icon(Icons.grid_view_outlined),selectedIcon:Icon(Icons.grid_view_rounded),label:'Shop'),
          NavigationDestination(icon:Icon(Icons.receipt_long_outlined),selectedIcon:Icon(Icons.receipt_long_rounded),label:'Orders'),
          NavigationDestination(icon:Icon(Icons.settings_outlined),selectedIcon:Icon(Icons.settings_rounded),label:'Settings'),
        ]));
  }
}

void openCart(BuildContext context, AppStore store) => Navigator.push(context,
  MaterialPageRoute(builder:(_)=>CartPage(store:store)));
void openProduct(BuildContext context, AppStore store, UniformProduct product)=>Navigator.push(context,
  MaterialPageRoute(builder:(_)=>ProductPage(product:product,store:store)));

class CartButton extends StatelessWidget {
  CartButton({super.key,required this.store});final AppStore store;
  @override Widget build(BuildContext context)=>IconButton(
    tooltip:'Open cart',onPressed:()=>openCart(context,store),
    icon:Badge(isLabelVisible:store.count>0,label:Text('${store.count}'),
      child:Icon(Icons.shopping_bag_outlined,color:navy)));
}

class ProductArt extends StatelessWidget {
  ProductArt(this.product,{super.key,this.height,this.width,this.radius=18});
  final UniformProduct product;final double? height,width,radius;
  @override Widget build(BuildContext context)=>Container(
    height:height,width:width,clipBehavior:Clip.antiAlias,
    decoration:BoxDecoration(color:warm,
      borderRadius:BorderRadius.circular(radius??18)),
    child:Stack(fit:StackFit.expand,children:[
      Padding(padding:const EdgeInsets.all(10),child:Image.asset('assets/products/${product.image}',
        fit:BoxFit.contain,errorBuilder:(_,__,___)=>Icon(Icons.image_not_supported_outlined,color:textMuted))),
      if(product.illustration) Positioned(bottom:7,left:7,right:7,
        child:Align(alignment:Alignment.centerLeft,child:Container(
          padding:const EdgeInsets.symmetric(horizontal:6,vertical:3),
          decoration:BoxDecoration(color:Colors.white.withOpacity(.93),borderRadius:BorderRadius.circular(7)),
          child:Text('ILLUSTRATION',style:TextStyle(color:textMuted,fontSize:8,fontWeight:FontWeight.w800,letterSpacing:.3))))),
    ]));
}

class ProductTile extends StatelessWidget {
  ProductTile({super.key,required this.product,required this.store});
  final UniformProduct product;final AppStore store;
  @override Widget build(BuildContext context)=>InkWell(onTap:()=>openProduct(context,store,product),
    borderRadius:BorderRadius.circular(20),child:Container(
      padding:const EdgeInsets.all(9),
      decoration:BoxDecoration(color:white,borderRadius:BorderRadius.circular(20),
        border:Border.all(color:stroke)),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Expanded(child:SizedBox(width:double.infinity,child:ProductArt(product,radius:14))),
        SizedBox(height:9),
        Text(product.name,maxLines:1,overflow:TextOverflow.ellipsis,
          style:TextStyle(fontSize:13,fontWeight:FontWeight.w800,color:textDark)),
        SizedBox(height:3),
        Text(product.section,maxLines:1,overflow:TextOverflow.ellipsis,
          style:TextStyle(fontSize:11,color:textMuted)),
        SizedBox(height:5),
        Text(product.startingPrice==null?'Price to confirm':'From ${money(product.startingPrice!)}',
          style:TextStyle(fontSize:12,color:navy,fontWeight:FontWeight.w900)),
      ])));
}

class HomePage extends StatelessWidget {
  const HomePage({super.key,required this.store,required this.onShop});
  final AppStore store;final ValueChanged<String> onShop;
  @override Widget build(BuildContext context){
    final picks=[productOf('college-polo'),productOf('college-skirt'),productOf('shs-m-vest'),productOf('neu-pants')];
    return ListView(padding:const EdgeInsets.fromLTRB(20,15,20,25),children:[
      Row(children:[Text('UniWear',style:TextStyle(
        fontFamily:'Avenir Next',fontSize:29,fontWeight:FontWeight.w800,
        color:textDark,letterSpacing:-1.1)),Spacer(),CartButton(store:store)]),
      SizedBox(height:21),
      Container(height:192,clipBehavior:Clip.antiAlias,decoration:BoxDecoration(
        gradient:LinearGradient(colors:[heroNavy,navyDeep]),borderRadius:BorderRadius.circular(25)),
        child:Stack(children:[
          Positioned(top:-35,right:-44,child:Container(width:218,height:218,
            decoration:BoxDecoration(shape:BoxShape.circle,border:Border.all(color:gold.withOpacity(.38),width:34)))),
          Positioned(right:-18,top:24,bottom:13,width:154,child:Image.asset('assets/products/college_polo.png',fit:BoxFit.contain)),
          Positioned(left:20,top:23,right:137,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('THE UNIFORM EDITION',style:TextStyle(color:gold,fontSize:10,fontWeight:FontWeight.w900,letterSpacing:1.6)),
            SizedBox(height:9),Text('Your campus.\nYour perfect fit.',
              style:TextStyle(color:Colors.white,fontSize:22,height:1.15,fontWeight:FontWeight.w900)),
            SizedBox(height:9),Text('Explore SHS, college & P.E. essentials.',
              style:TextStyle(color:Color(0xFFD8E0E5),fontSize:11,height:1.45)),
            SizedBox(height:12),SizedBox(height:34,child:FilledButton(
              style:FilledButton.styleFrom(backgroundColor:const Color(0xFFF4E6D2),foregroundColor:heroNavy,
                minimumSize:Size.zero,padding:const EdgeInsets.symmetric(horizontal:15),
                shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(11))),
              onPressed:()=>onShop('All'),child:Text('Shop now  →',style:TextStyle(fontWeight:FontWeight.w800,fontSize:12))))]))
        ])),
      SizedBox(height:22),SectionTitle('Shop by level'),SizedBox(height:10),
      Row(children:[
        Expanded(child:_levelCard(Icons.school_outlined,'Senior High','Grades 11–12',()=>onShop('Senior High'))),
        SizedBox(width:10),
        Expanded(child:_levelCard(Icons.account_balance_outlined,'College','University',()=>onShop('College'))),
      ]),
      SizedBox(height:10),
      InkWell(onTap:()=>onShop('Integrated'),borderRadius:BorderRadius.circular(16),
        child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:white,
          borderRadius:BorderRadius.circular(16),border:Border.all(color:stroke)),
          child:Row(children:[Icon(Icons.sports_outlined,color:navy),SizedBox(width:10),
            Expanded(child:Text('Integrated School & P.E.',style:TextStyle(fontWeight:FontWeight.w800))),
            Icon(Icons.arrow_forward_ios_rounded,color:textMuted,size:14)]))),
      SizedBox(height:25),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        SectionTitle('Popular uniforms'),TextButton(onPressed:()=>onShop('All'),child:Text('See all →'))]),
      SizedBox(height:250,child:ListView.separated(scrollDirection:Axis.horizontal,itemCount:picks.length,
        separatorBuilder:(_,__)=>SizedBox(width:12),itemBuilder:(context,i)=>SizedBox(
          width:165,child:ProductTile(product:picks[i],store:store)))),
    ]);
  }
  Widget _levelCard(IconData icon,String name,String subtitle,VoidCallback tap)=>InkWell(
    onTap:tap,borderRadius:BorderRadius.circular(17),child:Container(height:110,
      padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:white,
        borderRadius:BorderRadius.circular(17),border:Border.all(color:stroke)),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Icon(icon,color:navy,size:23),Spacer(),Text(name,style:TextStyle(fontWeight:FontWeight.w800,fontSize:14)),
        Text(subtitle,style:TextStyle(color:textMuted,fontSize:10))])));
}

class SectionTitle extends StatelessWidget {
  SectionTitle(this.label,{super.key});final String label;
  @override Widget build(BuildContext context)=>Text(label,style:TextStyle(
    fontSize:18,fontWeight:FontWeight.w900,color:textDark,letterSpacing:-.35));
}

class ShopPage extends StatefulWidget {
  const ShopPage({super.key,required this.store,required this.initialSection});
  final AppStore store;final String initialSection;
  @override State<ShopPage> createState()=>_ShopPageState();
}
class _ShopPageState extends State<ShopPage> {
  late String section;
  String query=''; String group='All';
  @override void initState(){super.initState();section=widget.initialSection;}
  @override Widget build(BuildContext context){
    final shown=catalog.where((p)=>(section=='All'||p.section==section)
      &&(group=='All'||p.group==group)
      &&('${p.name} ${p.group} ${p.section}'.toLowerCase().contains(query.toLowerCase()))).toList();
    final width=MediaQuery.sizeOf(context).width;
    return CustomScrollView(slivers:[SliverToBoxAdapter(child:Padding(
      padding:const EdgeInsets.fromLTRB(20,14,20,17),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[Expanded(child:Text('Shop uniforms',style:TextStyle(
          fontSize:26,fontWeight:FontWeight.w900,color:textDark))),CartButton(store:widget.store)]),
        SizedBox(height:4),Text('Find the right pieces for every school day.',style:TextStyle(color:textMuted,fontSize:12)),
        SizedBox(height:17),TextField(onChanged:(v)=>setState(()=>query=v),
          decoration:InputDecoration(prefixIcon:Icon(Icons.search,color:navy),hintText:'Search uniforms, pants, skirts…',isDense:true)),
        SizedBox(height:15),SingleChildScrollView(scrollDirection:Axis.horizontal,
          child:Row(children:['All','Senior High','College','Integrated'].map((s)=>Padding(
            padding:const EdgeInsets.only(right:8),child:ChoiceChip(label:Text(s),selected:section==s,
              selectedColor:_uniwearDark ? const Color(0xFF425264) : const Color(0xFFE8DCCC),backgroundColor:white,
              onSelected:(_)=>setState((){section=s;group='All';})))).toList())),
        SizedBox(height:8),SingleChildScrollView(scrollDirection:Axis.horizontal,
          child:Row(children:['All','Male','Female','Accessories','P.E.'].map((s)=>Padding(
            padding:const EdgeInsets.only(right:8),child:FilterChip(label:Text(s),selected:group==s,
              onSelected:(_)=>setState(()=>group=s)))).toList())),
        SizedBox(height:15),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          SectionTitle('All products'),Text('${shown.length} items',style:TextStyle(color:textMuted,fontSize:12))]),
      ]))),
      if(shown.isEmpty)SliverFillRemaining(child:Center(child:Text('No uniforms match these filters.')))
      else SliverPadding(padding:const EdgeInsets.fromLTRB(18,0,18,25),sliver:SliverGrid.builder(
        itemCount:shown.length,gridDelegate:SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount:width>650?3:2,mainAxisSpacing:12,crossAxisSpacing:12,childAspectRatio:width > 650 ? 0.76 : 0.67),
        itemBuilder:(context,i)=>ProductTile(product:shown[i],store:widget.store))),
    ]);
  }
}

class ProductPage extends StatefulWidget {
  const ProductPage({super.key,required this.product,required this.store});
  final UniformProduct product;final AppStore store;
  @override State<ProductPage> createState()=>_ProductPageState();
}
class _ProductPageState extends State<ProductPage> {
  String? size;int qty=1;
  @override void initState(){super.initState();if(widget.product.canOrder)size=widget.product.prices.keys.first;}
  @override Widget build(BuildContext context){final p=widget.product;
    return Scaffold(appBar:AppBar(title:Text('Product details'),actions:[CartButton(store:widget.store)]),
      body:Column(children:[Expanded(child:ListView(padding:const EdgeInsets.fromLTRB(19,5,19,20),children:[
        AspectRatio(aspectRatio:1.08,child:ProductArt(p,radius:23)),
        SizedBox(height:19),Text('${p.section.toUpperCase()}  /  ${p.group.toUpperCase()}',
          style:TextStyle(color:gold,fontWeight:FontWeight.w900,fontSize:10,letterSpacing:1.2)),
        SizedBox(height:6),Text(p.name,style:TextStyle(fontWeight:FontWeight.w900,fontSize:26,color:textDark)),
        SizedBox(height:7),Text(p.description,style:TextStyle(color:textMuted,fontSize:13,height:1.55)),
        if(p.illustration||p.needsVerification)...[SizedBox(height:10),
          Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(
            color:_uniwearDark ? const Color(0xFF463B2B) : const Color(0xFFFFF3E4),borderRadius:BorderRadius.circular(12)),
            child:Text(p.illustration?'Illustrative image — supplier product photo has not been verified.':'Photo category needs supplier verification before live use.',
              style:TextStyle(color:Color(0xFF88633A),fontSize:11,height:1.35)))],
        if(p.sources.isNotEmpty)...[SizedBox(height:10),TextButton.icon(
          onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SourceGalleryPage(
            selected:p.sources.map((n)=>n).toList()))),
          icon:Icon(Icons.photo_library_outlined,size:17),label:Text('View original photographed samples'))],
        SizedBox(height:19),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          SectionTitle('Choose a size'),TextButton.icon(onPressed:()=>Navigator.push(context,
            MaterialPageRoute(builder:(_)=>SizeGuidePage())),icon:Icon(Icons.straighten,size:17),label:Text('Size tips'))]),
        if(!p.canOrder)Padding(padding:EdgeInsets.symmetric(vertical:12),child:Text(
          'This item is on display only. The photographed price sheet did not show a reliable price.',
          style:TextStyle(fontSize:12,color:textMuted)))
        else Wrap(spacing:8,runSpacing:8,children:p.prices.entries.map((entry)=>ChoiceChip(
          label:Text('${entry.key} · ${money(entry.value)}'),selected:size==entry.key,
          selectedColor:_uniwearDark ? const Color(0xFF425264) : const Color(0xFFE6D9C9),backgroundColor:white,
          onSelected:(_)=>setState(()=>size=entry.key))).toList()),
        SizedBox(height:21),Row(children:[Expanded(child:SectionTitle('Quantity')),
          IconButton.filledTonal(onPressed:qty>1?()=>setState(()=>qty--):null,icon:Icon(Icons.remove)),
          Padding(padding:const EdgeInsets.symmetric(horizontal:17),child:Text('$qty',
            style:TextStyle(fontSize:17,fontWeight:FontWeight.w800))),
          IconButton.filledTonal(onPressed:qty<10?()=>setState(()=>qty++):null,icon:Icon(Icons.add))]),
      ])),
      Container(padding:EdgeInsets.fromLTRB(19,12,19,12+MediaQuery.paddingOf(context).bottom),
        decoration:BoxDecoration(color:white,border:Border(top:BorderSide(color:stroke))),
        child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,
          children:[Text('Total',style:TextStyle(color:textMuted,fontSize:11)),
            AnimatedSwitcher(duration:Duration(milliseconds:170), child:Text(size==null?'Not available':money((p.prices[size]??0)*qty),
              key:ValueKey('$size/$qty'),style:TextStyle(color:navy,fontSize:19,fontWeight:FontWeight.w900)))])),
          Expanded(flex:2,child:FilledButton.icon(onPressed:size==null?null:(){
            widget.store.add(p,size!,qty);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Added to your cart')));
            Navigator.pop(context);},icon:Icon(Icons.shopping_bag_outlined,size:19),
            label:Text(size==null?'Unavailable':'Add to cart')))])),
    ]));
  }
}

class CartPage extends StatelessWidget {
  const CartPage({super.key,required this.store});final AppStore store;
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:store,builder:(_,__)=>Scaffold(
    appBar:AppBar(title:Text('My cart (${store.count})')),
    body:store.cart.isEmpty?EmptyPanel(icon:Icons.shopping_bag_outlined,
      heading:'Your cart is empty',detail:'Explore the uniform catalog to add your first item.',
      action:'Continue shopping',onAction:()=>Navigator.pop(context)):
      Column(children:[Expanded(child:ListView.separated(padding:const EdgeInsets.all(18),
        itemCount:store.cart.length,separatorBuilder:(_,__)=>SizedBox(height:12),
        itemBuilder:(context,i){final line=store.cart[i];final p=productOf(line.id);
          return Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:white,
            borderRadius:BorderRadius.circular(17),border:Border.all(color:stroke)),
            child:Row(children:[ProductArt(p,width:96,height:107,radius:13),SizedBox(width:13),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(p.name,style:TextStyle(fontSize:13,fontWeight:FontWeight.w800)),
                Text('Size ${line.size}  •  ${money(line.unit)} each',
                  style:TextStyle(color:textMuted,fontSize:10)),
                SizedBox(height:7),Text(money(line.total),style:TextStyle(color:navy,
                  fontSize:14,fontWeight:FontWeight.w900)),
                Row(mainAxisSize:MainAxisSize.min,children:[
                  IconButton(onPressed:()=>store.quantity(line,-1),visualDensity:VisualDensity.compact,
                    icon:Icon(Icons.remove_circle_outline,size:20)),
                  Text('${line.quantity}',style:TextStyle(fontWeight:FontWeight.w700)),
                  IconButton(onPressed:()=>store.quantity(line,1),visualDensity:VisualDensity.compact,
                    icon:Icon(Icons.add_circle_outline,size:20)),
                ])]))]));})),
      Container(padding:EdgeInsets.fromLTRB(19,15,19,14+MediaQuery.paddingOf(context).bottom),
        decoration:BoxDecoration(color:white,border:Border(top:BorderSide(color:stroke))),
        child:Column(children:[Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          Text('Order total',style:TextStyle(fontWeight:FontWeight.w800)),
          Text(money(store.total),style:TextStyle(color:navy,fontSize:21,fontWeight:FontWeight.w900))]),
          SizedBox(height:13),SizedBox(width:double.infinity,child:FilledButton(
            onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CheckoutPage(store:store))),
            child:Text('Proceed to checkout')))]))])));
}


class CheckoutPage extends StatefulWidget {
  const CheckoutPage({super.key, required this.store});
  final AppStore store;
  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  bool _submitting = false;

  Future<void> _placeOrder() async {
    if (widget.store.cart.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() => _submitting = true);
    try {
      final orderNumber = await widget.store.placeOrder();
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(
        builder: (_) => SuccessPage(reference: orderNumber),
      ));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString()), backgroundColor: Theme.of(context).colorScheme.error),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.store.profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        SectionTitle('Student information'),
        const SizedBox(height: 9),
        Card(child: ListTile(
          leading: Icon(Icons.person_outline, color: navy),
          title: Text(profile['full_name']?.toString() ?? 'Student'),
          subtitle: Text(profile['student_number']?.toString() ?? ''),
        )),
        const SizedBox(height: 22),
        SectionTitle('Pickup & payment'),
        const SizedBox(height: 10),
        Card(child: ListTile(
          leading: Icon(Icons.storefront_outlined, color: navy),
          title: const Text('Campus counter pickup'),
          subtitle: const Text('Pay at counter'),
        )),
        const SizedBox(height: 21),
        SectionTitle('Order summary'),
        const SizedBox(height: 9),
        ...widget.store.cart.map((item) => ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(productOf(item.id).name),
          subtitle: Text('Size ${item.size} · Qty ${item.quantity}'),
          trailing: Text(money(item.total)),
        )),
        Divider(color: stroke),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Estimated total', style: TextStyle(fontWeight: FontWeight.w800)),
          Text(money(widget.store.total),
            style: TextStyle(fontWeight: FontWeight.w900, color: navy, fontSize: 20)),
        ]),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _submitting ? null : _placeOrder,
          child: Text(_submitting ? 'Placing order…' : 'Place order'),
        ),
      ]),
    );
  }
}


class SuccessPage extends StatelessWidget {
  const SuccessPage({super.key, required this.reference});
  final String reference;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: Padding(
      padding: const EdgeInsets.all(30),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check_circle_rounded, color: navy, size: 84),
        const SizedBox(height: 17),
        const Text('Order placed!', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 24)),
        const SizedBox(height: 7),
        Text('Your order is saved. Track its progress in My Orders.',
          style: TextStyle(color: textMuted), textAlign: TextAlign.center),
        const SizedBox(height: 15),
        SelectableText(reference,
          style: TextStyle(fontWeight: FontWeight.w900, color: navy, fontSize: 19)),
        const SizedBox(height: 24),
        SizedBox(width: double.infinity, child: FilledButton(
          onPressed: () => Navigator.popUntil(context, (route) => route.isFirst),
          child: const Text('Back to UniWear'),
        )),
      ]),
    ))),
  );
}


class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key, required this.store});
  final AppStore store;
  static const steps = ['Pending', 'Confirmed', 'Preparing', 'Ready for Pickup', 'Completed'];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (_, __) => Scaffold(
      appBar: AppBar(title: const Text('My orders')),
      body: store.orders.isEmpty
        ? EmptyPanel(icon: Icons.inventory_2_outlined,
            heading: 'No orders yet', detail: 'Your orders will appear here.')
        : ListView.separated(
          padding: const EdgeInsets.all(18),
          itemCount: store.orders.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            final order = store.orders[i];
            final status = order['status'] as String? ?? 'Pending';
            final position = steps.indexOf(status);
            final created = DateTime.tryParse(order['created_at']?.toString() ?? '')?.toLocal();
            final items = (order['order_items'] as List? ?? const [])
              .map((item) => Map<String, dynamic>.from(item as Map)).toList();
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: stroke)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('Order #${order['order_number']}',
                    style: TextStyle(fontWeight: FontWeight.w900, color: navy, fontSize: 14))),
                  Chip(label: Text(status)),
                ]),
                Text(created == null ? '' : '${created.month}/${created.day}/${created.year}',
                  style: TextStyle(fontSize: 11, color: textMuted)),
                const SizedBox(height: 9),
                ...items.map((item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('${item['quantity']}× ${item['product_name']} · ${item['size']}',
                    style: const TextStyle(fontSize: 12)),
                )),
                Divider(color: stroke),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Total', style: TextStyle(color: textMuted)),
                  Text(money(order['total_php'] as int),
                    style: TextStyle(fontWeight: FontWeight.w900, color: navy)),
                ]),
                const SizedBox(height: 12),
                const Text('Order progress', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                if (status == 'Cancelled')
                  Text('This order was cancelled.', style: TextStyle(color: textMuted, fontSize: 12))
                else ...steps.map((step) {
                  final index = steps.indexOf(step);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Icon(index <= position ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: index <= position ? navy : const Color(0xFFC8C7C4), size: 17),
                      const SizedBox(width: 9),
                      Text(step, style: TextStyle(fontSize: 12,
                        color: index <= position ? textDark : textMuted,
                        fontWeight: index <= position ? FontWeight.w700 : FontWeight.w400)),
                    ]),
                  );
                }),
                if (status == 'Pending') ...[
                  const SizedBox(height: 13),
                  SizedBox(width: double.infinity, child: OutlinedButton.icon(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Cancel order'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFAF4242),
                      side: const BorderSide(color: Color(0xFFCF8E8E)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _confirmCancelOrder(context, order),
                  )),
                ],
              ]),
            );
          },
        ),
    ),
  );

  Future<void> _confirmCancelOrder(BuildContext context, Map<String, dynamic> order) async {
    if (order['status'] != 'Pending') return;
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this order?'),
        content: Text('Order #${order['order_number']} is still pending. '
          'If cancelled, it will remain in your order history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep order')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes, cancel')),
        ],
      ),
    );
    if (shouldCancel == true && context.mounted) {
      try {
        await store.cancelPendingOrder(order);
      } catch (error) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    }
  }
}


class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(19, 18, 19, 26),
    children: [
      Text('Settings', style: TextStyle(fontSize: 28, color: textDark,
        fontWeight: FontWeight.w900, letterSpacing: -0.7)),
      const SizedBox(height: 6),
      Text('Make UniWear yours.', style: TextStyle(color: textMuted)),
      const SizedBox(height: 23),
      _settingsRow(context, Icons.straighten_outlined,
        'Size selection guide', 'Choose the right uniform size', () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => SizeGuidePage()))),
      if (store.isAdmin)
        _settingsRow(context, Icons.admin_panel_settings_outlined,
          'Admin console', 'Manage student orders', () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => AdminPage(store: store)))),
      const SizedBox(height: 14),
      Text('APPEARANCE', style: TextStyle(color: textMuted,
        fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.3)),
      const SizedBox(height: 9),
      Container(
        decoration: BoxDecoration(color: white, border: Border.all(color: stroke),
          borderRadius: BorderRadius.circular(17)),
        child: SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          secondary: Icon(store.darkMode ? Icons.dark_mode_outlined : Icons.light_mode_outlined, color: navy),
          title: Text('Dark mode', style: TextStyle(fontWeight: FontWeight.w800, color: textDark)),
          subtitle: Text(store.darkMode ? 'Dark appearance enabled' : 'Light appearance enabled',
            style: TextStyle(color: textMuted, fontSize: 11)),
          value: store.darkMode,
          onChanged: store.setDarkMode,
        ),
      ),
      const SizedBox(height: 18),
      Text('ACCOUNT', style: TextStyle(color: textMuted,
        fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.3)),
      const SizedBox(height: 9),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: white, borderRadius: BorderRadius.circular(17),
          border: Border.all(color: stroke)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Signed in as', style: TextStyle(color: textMuted, fontSize: 11)),
          const SizedBox(height: 4),
          Text(store.profile['full_name']?.toString() ?? '',
            style: TextStyle(color: textDark, fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text('Student number: ${store.profile['student_number'] ?? ''}',
            style: TextStyle(color: textMuted, fontSize: 11)),
          const SizedBox(height: 11),
          OutlinedButton.icon(
            onPressed: () async {
              final shouldSignOut = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Sign out of UniWear?'),
                  content: const Text('Your cart remains saved on this device.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Sign out')),
                  ],
                ),
              );
              if (shouldSignOut == true) await store.signOut();
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
        ]),
      ),
    ],
  );

  Widget _settingsRow(BuildContext context, IconData icon, String title,
    String description, VoidCallback action) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Material(
      color: white,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: action,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(17),
            border: Border.all(color: stroke)),
          child: Row(children: [
            Icon(icon, color: navy, size: 22),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(color: textDark, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(description, style: TextStyle(color: textMuted, fontSize: 11)),
            ])),
            Icon(Icons.chevron_right_rounded, color: textMuted),
          ]),
        ),
      ),
    ),
  );
}

class SizeGuidePage extends StatelessWidget {
  SizeGuidePage({super.key});
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('Size selection guide')),
    body:ListView(padding:const EdgeInsets.all(20),children:[
      SectionTitle('Find the right size'),SizedBox(height:10),
      Text('The photographed counter lists provide size names and prices, but not physical body measurements. '
        'We do not invent chest, waist, or length measurements.',
        style:TextStyle(color:textMuted,height:1.6)),SizedBox(height:15),
      Card(child:ListTile(leading:Icon(Icons.checkroom_outlined,color:navy),
        title:Text('Blouses, vests and polos'),subtitle:Text('Choose XS, S, M, L or an XL size shown for that product.'))),
      Card(child:ListTile(leading:Icon(Icons.straighten_outlined,color:navy),
        title:Text('Numbered pants & skirts'),subtitle:Text('Select the size number (#24, #26, #28, etc.) printed for your item.'))),
      Card(child:ListTile(leading:Icon(Icons.store_outlined,color:navy),
        title:Text('Before paying'),subtitle:Text('Try on a sample at the uniform counter and confirm availability.'))),
      SizedBox(height:14),FilledButton.icon(onPressed:()=>Navigator.push(context,
        MaterialPageRoute(builder:(_)=>SourceGalleryPage(selected:[543,544]))),
        icon:Icon(Icons.image_outlined),label:Text('View original price lists')),
    ]));
}

class SourceGalleryPage extends StatelessWidget {
  SourceGalleryPage({super.key,this.selected});
  final List<int>? selected;
  @override Widget build(BuildContext context){final ids=selected==null ? const <int>[527,528,530,532,534,536,539,540,543,544] : selected!.toSet().toList();
    return Scaffold(appBar:AppBar(title:Text(selected==null?'Original photo archive':'Original source photos')),
      body:GridView.builder(padding:const EdgeInsets.all(13),itemCount:ids.length,
        gridDelegate:SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,
          crossAxisSpacing:9,mainAxisSpacing:9,childAspectRatio:.71),
        itemBuilder:(context,i){final n=ids[i];final path='assets/original_photos/IMG_0$n.jpg';
          return InkWell(onTap:()=>Navigator.push(context,MaterialPageRoute(
            builder:(_)=>SourceViewerPage(ids:ids,initial:i))),
            child:Container(clipBehavior:Clip.antiAlias,decoration:BoxDecoration(
              color:warm,borderRadius:BorderRadius.circular(12)),
              child:Stack(fit:StackFit.expand,children:[Image.asset(path,fit:BoxFit.cover),
                Positioned(bottom:0,left:0,right:0,child:Container(color:heroNavy.withOpacity(.83),
                  padding:const EdgeInsets.all(6),child:Text('IMG_0$n',textAlign:TextAlign.center,
                    style:TextStyle(color:Colors.white,fontSize:10,fontWeight:FontWeight.w800))))])));}),
    );
  }
}

class SourceViewerPage extends StatefulWidget {
  const SourceViewerPage({super.key,required this.ids,required this.initial});
  final List<int> ids;final int initial;
  @override State<SourceViewerPage> createState()=>_SourceViewerPageState();
}
class _SourceViewerPageState extends State<SourceViewerPage> {
  late final PageController controller;
  late int current;
  @override void initState(){super.initState();current=widget.initial;
    controller=PageController(initialPage:widget.initial);}
  @override void dispose(){controller.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(
    backgroundColor:const Color(0xFF12171D),
    appBar:AppBar(backgroundColor:const Color(0xFF12171D),foregroundColor:Colors.white,
      title:Text('IMG_0${widget.ids[current]}  ·  ${current+1}/${widget.ids.length}')),
    body:PageView.builder(controller:controller,itemCount:widget.ids.length,
      onPageChanged:(v)=>setState(()=>current=v),itemBuilder:(context,i)=>InteractiveViewer(
        minScale:1,maxScale:5,child:Center(child:Image.asset(
          'assets/original_photos/IMG_0${widget.ids[i]}.jpg',fit:BoxFit.contain)))));
}


class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.store});
  final AppStore store;
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() { _loading = true; _error = null; });
    try {
      await widget.store.refreshAdminOrders();
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<String> _allowedNext(String status) {
    switch (status) {
      case 'Pending': return ['Confirmed', 'Cancelled'];
      case 'Confirmed': return ['Preparing', 'Cancelled'];
      case 'Preparing': return ['Ready for Pickup', 'Cancelled'];
      case 'Ready for Pickup': return ['Completed', 'Cancelled'];
      default: return [];
    }
  }

  Future<void> _setStatus(Map<String, dynamic> order, String next) async {
    try {
      await widget.store.updateOrderStatus(order, next);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Admin'),
      actions: [IconButton(onPressed: _loading ? null : _refresh,
        icon: const Icon(Icons.refresh))],
    ),
    body: !_loading && _error != null
      ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        )))
      : _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(padding: const EdgeInsets.all(18), children: [
          Row(children: [
            Expanded(child: _metric('Orders', '${widget.store.adminOrders.length}')),
            const SizedBox(width: 10),
            Expanded(child: _metric('Order total', money(widget.store.adminOrders.fold<int>(
              0, (sum, order) => sum + (order['total_php'] as int))))),
          ]),
          const SizedBox(height: 22),
          SectionTitle('Manage orders'),
          const SizedBox(height: 12),
          if (widget.store.adminOrders.isEmpty)
            Text('No orders have been placed yet.', style: TextStyle(color: textMuted)),
          ...widget.store.adminOrders.map((order) {
            final status = order['status'] as String;
            final items = (order['items'] as List? ?? const [])
              .map((item) => Map<String, dynamic>.from(item as Map)).toList();
            final nextChoices = _allowedNext(status);
            return Card(child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(order['order_number'] as String,
                  style: TextStyle(fontWeight: FontWeight.w900, color: navy)),
                const SizedBox(height: 5),
                Text('${order['student_name']} · ${order['student_number']}',
                  style: TextStyle(fontSize: 12, color: textMuted)),
                const SizedBox(height: 6),
                Text('${items.length} line items · ${money(order['total_php'] as int)}'),
                ...items.map((item) => Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('${item['quantity']}× ${item['product_name']} · ${item['size']}',
                    style: TextStyle(fontSize: 11, color: textMuted)),
                )),
                const SizedBox(height: 9),
                if (nextChoices.isEmpty)
                  Text(status, style: TextStyle(fontWeight: FontWeight.w700, color: textMuted))
                else
                  DropdownButtonFormField<String>(
                    value: null,
                    items: nextChoices.map((value) => DropdownMenuItem(
                      value: value, child: Text(value))).toList(),
                    decoration: const InputDecoration(labelText: 'Change status', isDense: true),
                    onChanged: (next) { if (next != null) _setStatus(order, next); },
                  ),
              ]),
            ));
          }),
        ]),
  );

  Widget _metric(String name, String value) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: white, borderRadius: BorderRadius.circular(17),
      border: Border.all(color: stroke)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: TextStyle(fontSize: 19, color: navy, fontWeight: FontWeight.w900)),
      Text(name, style: TextStyle(fontSize: 11, color: textMuted)),
    ]),
  );
}

class EmptyPanel extends StatelessWidget {
  EmptyPanel({super.key,required this.icon,required this.heading,required this.detail,
    this.action,this.onAction});
  final IconData icon;final String heading,detail;final String? action;
  final VoidCallback? onAction;
  @override Widget build(BuildContext context)=>Center(child:Padding(
    padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[
      Icon(icon,color:gold,size:66),SizedBox(height:13),Text(heading,
        style:TextStyle(fontSize:21,fontWeight:FontWeight.w900)),
      SizedBox(height:7),Text(detail,textAlign:TextAlign.center,
        style:TextStyle(color:textMuted,fontSize:12)),
      if(action!=null)...[SizedBox(height:17),FilledButton(
        onPressed:onAction,child:Text(action!))]])));
}
