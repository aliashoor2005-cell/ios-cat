#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>

// Cat Printer (GB01/GB02/GB03/GT01/MX...) BLE service / write characteristic
#define CAT_SERVICE_UUID @"AE30"
#define CAT_WRITE_UUID   @"AE01"
#define LAST_PRINTER_KEY @"lastPrinterId"

// JS <-> native bridge
//   JS -> native: the page queues commands in window.__nativeQueue and loads
//                 catprint://flush; native pulls them with __flushNativeQueue().
//                 Commands: scan, stopScan, connect(id), disconnect, print.
//   native -> JS: onScanState(bool), onDeviceFound({...}), onPrinterState({...}),
//                 setStatus(text), onPrintProgress(percent), onPrintDone(ok, text)

@interface AppDelegate : UIResponder <UIApplicationDelegate, UIWebViewDelegate, CBCentralManagerDelegate, CBPeripheralDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) UIWebView *webView;
@property (strong, nonatomic) CBCentralManager *centralManager;
@property (strong, nonatomic) NSMutableDictionary *discovered;   // id -> CBPeripheral
@property (strong, nonatomic) CBPeripheral *printerPeripheral;
@property (strong, nonatomic) CBCharacteristic *writeCharacteristic;
@property (strong, nonatomic) NSString *printerName;
@property (strong, nonatomic) NSData *pendingPrintData;
@property (assign, nonatomic) NSUInteger sendOffset;
@property (assign, nonatomic) BOOL sending;
@property (assign, nonatomic) BOOL scanning;
@property (assign, nonatomic) NSInteger scanToken;
@property (assign, nonatomic) BOOL pageReady;
@end

@implementation AppDelegate

#pragma mark - JS helpers

- (void)runJS:(NSString *)js {
    if (!self.pageReady) return;
    if ([NSThread isMainThread]) {
        [self.webView stringByEvaluatingJavaScriptFromString:js];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.webView stringByEvaluatingJavaScriptFromString:js];
        });
    }
}

- (NSString *)json:(id)obj {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[obj ?: [NSNull null]] options:0 error:nil];
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [arr substringWithRange:NSMakeRange(1, [arr length] - 2)];
}

- (void)call:(NSString *)fn arg:(id)arg {
    [self runJS:[NSString stringWithFormat:@"if(window.%@){%@(%@);}", fn, fn, [self json:arg]]];
}

- (void)setStatus:(NSString *)msg { [self call:@"setStatus" arg:msg]; }

- (void)printDone:(BOOL)ok message:(NSString *)msg {
    [self runJS:[NSString stringWithFormat:@"if(window.onPrintDone){onPrintDone(%@,%@);}", ok ? @"true" : @"false", [self json:msg]]];
}

- (void)pushPrinterState {
    NSString *state = @"none";
    if (self.printerPeripheral) {
        if (self.printerPeripheral.state == CBPeripheralStateConnected && self.writeCharacteristic) state = @"connected";
        else state = @"connecting";
    }
    NSString *lastId = [[NSUserDefaults standardUserDefaults] stringForKey:LAST_PRINTER_KEY];
    [self call:@"onPrinterState" arg:@{
        @"state": state,
        @"name": self.printerName ?: @"",
        @"id": self.printerPeripheral ? [self idOf:self.printerPeripheral] : @"",
        @"lastId": lastId ?: @"",
        @"bluetooth": @(self.centralManager.state == CBCentralManagerStatePoweredOn)
    }];
}

- (NSString *)idOf:(CBPeripheral *)p {
    return [p.identifier UUIDString];
}

#pragma mark - App

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.discovered = [NSMutableDictionary dictionary];
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor whiteColor];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor colorWithRed:0.953 green:0.957 blue:0.965 alpha:1.0];

    CGRect frame = vc.view.bounds;
    frame.origin.y += 20.0;
    frame.size.height -= 20.0;
    self.webView = [[UIWebView alloc] initWithFrame:frame];
    self.webView.delegate = self;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = vc.view.backgroundColor;
    self.webView.opaque = NO;
    self.webView.scrollView.bounces = NO;
    [vc.view addSubview:self.webView];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    NSString *html = htmlPath ? [NSString stringWithContentsOfFile:htmlPath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (html) {
        // loadHTMLString avoids a static reference to NSURLRequest, whose home
        // framework differs between iOS 8 (Foundation) and iOS 9+ (CFNetwork).
        NSURL *baseUrl = [NSURL fileURLWithPath:[htmlPath stringByDeletingLastPathComponent] isDirectory:YES];
        [self.webView loadHTMLString:html baseURL:baseUrl];
    } else {
        [self.webView loadHTMLString:@"<h3 style='font-family:sans-serif;text-align:center;margin-top:40px;'>لم يتم العثور على ملف index.html داخل Resources</h3>" baseURL:nil];
    }

    self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    return YES;
}

#pragma mark - Web bridge

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    self.pageReady = YES;
    [self pushPrinterState];
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType {
    NSURL *url = [request URL];
    if ([[[url scheme] lowercaseString] isEqualToString:@"catprint"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self flushQueue]; });
        return NO;
    }
    return YES;
}

- (void)flushQueue {
    NSString *s = [self.webView stringByEvaluatingJavaScriptFromString:@"window.__flushNativeQueue ? __flushNativeQueue() : '[]'"];
    NSArray *cmds = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![cmds isKindOfClass:[NSArray class]]) return;
    for (NSDictionary *c in cmds) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSString *cmd = c[@"cmd"];
        if ([cmd isEqualToString:@"scan"]) [self startScan];
        else if ([cmd isEqualToString:@"stopScan"]) [self stopScan];
        else if ([cmd isEqualToString:@"connect"]) [self connectTo:c[@"id"]];
        else if ([cmd isEqualToString:@"disconnect"]) [self disconnect];
        else if ([cmd isEqualToString:@"print"]) [self handlePrint:c[@"data"]];
        else if ([cmd isEqualToString:@"state"]) [self pushPrinterState];
    }
}

#pragma mark - Scanning

- (BOOL)bluetoothReady {
    if (self.centralManager.state == CBCentralManagerStatePoweredOn) return YES;
    if (self.centralManager.state == CBCentralManagerStateUnsupported) {
        [self setStatus:@"هذا الجهاز لا يدعم بلوتوث BLE."];
    } else if (self.centralManager.state == CBCentralManagerStateUnauthorized) {
        [self setStatus:@"التطبيق غير مسموح له باستخدام البلوتوث. فعّل الإذن من الإعدادات > الخصوصية > البلوتوث."];
    } else if (self.centralManager.state == CBCentralManagerStateUnknown || self.centralManager.state == CBCentralManagerStateResetting) {
        [self setStatus:@"البلوتوث يتهيأ... انتظر ثانية ثم اضغط بحث مرة أخرى."];
    } else {
        [self setStatus:@"البلوتوث غير مفعل. شغّله من الإعدادات أو مركز التحكم."];
    }
    return NO;
}

- (void)startScan {
    if (![self bluetoothReady]) { [self call:@"onScanState" arg:@NO]; return; }
    if (self.scanning) [self.centralManager stopScan];
    self.scanning = YES;
    [self.discovered removeAllObjects];
    // keep the connected printer in the list
    if (self.printerPeripheral) self.discovered[[self idOf:self.printerPeripheral]] = self.printerPeripheral;
    [self call:@"onScanState" arg:@YES];
    [self setStatus:@"جاري البحث عن الطابعات..."];

    // A printer that is already connected to this iPad/iPhone (by another app,
    // or a previous session) stops advertising, so a scan alone never finds it.
    NSArray *services = @[[CBUUID UUIDWithString:@"AE30"], [CBUUID UUIDWithString:@"AF30"], [CBUUID UUIDWithString:@"18F0"]];
    for (CBPeripheral *p in [self.centralManager retrieveConnectedPeripheralsWithServices:services]) {
        [self reportPeripheral:p name:p.name rssi:-50 likely:YES];
    }

    [self.centralManager scanForPeripheralsWithServices:nil
                                                options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    NSInteger token = ++self.scanToken;
    __weak AppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AppDelegate *s = weakSelf;
        if (s && s.scanning && s.scanToken == token) {
            [s stopScan];
            if ([s.discovered count]) {
                [s setStatus:[NSString stringWithFormat:@"انتهى البحث: %lu جهاز. اختر الطابعة من القائمة.", (unsigned long)[s.discovered count]]];
            } else {
                [s setStatus:@"لم يُعثر على أي جهاز بلوتوث. أعد تشغيل الطابعة، وأغلق أي تطبيق طباعة آخر متصل بها، ثم ابحث مجدداً."];
            }
        }
    });
}

- (void)reportPeripheral:(CBPeripheral *)peripheral name:(NSString *)name rssi:(NSInteger)rssi likely:(BOOL)likely {
    NSString *pid = [self idOf:peripheral];
    self.discovered[pid] = peripheral;  // must be retained or CoreBluetooth drops it
    if (rssi == 127 || rssi == 0) rssi = -100;
    [self call:@"onDeviceFound" arg:@{
        @"id": pid,
        @"name": [name length] ? name : @"",
        @"rssi": @(rssi),
        @"likely": @(likely)
    }];
}

- (void)stopScan {
    if (self.scanning) [self.centralManager stopScan];
    self.scanning = NO;
    [self call:@"onScanState" arg:@NO];
}

- (BOOL)looksLikeCatPrinter:(NSString *)name advertisement:(NSDictionary *)adv {
    NSArray *uuids = adv[CBAdvertisementDataServiceUUIDsKey];
    for (CBUUID *u in uuids) {
        NSString *s = [[u UUIDString] uppercaseString];
        if ([s isEqualToString:@"AE30"] || [s isEqualToString:@"AF30"]) return YES;
    }
    if ([name length] == 0) return NO;
    NSString *u = [name uppercaseString];
    NSArray *prefixes = @[@"GB0", @"GT0", @"MX0", @"MX1", @"YT0", @"BQ", @"LY0", @"AI0", @"X5", @"X6"];
    for (NSString *p in prefixes) {
        if ([u hasPrefix:p]) return YES;
    }
    return [u rangeOfString:@"CAT"].location != NSNotFound ||
           [u rangeOfString:@"PRINT"].location != NSNotFound;
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI {
    NSString *name = advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name;
    // Unnamed devices are reported too (the page shows them under "show all"),
    // since some printers only send their name in a later scan response.
    [self reportPeripheral:peripheral name:name rssi:[RSSI integerValue]
                    likely:[self looksLikeCatPrinter:name advertisement:advertisementData]];
}

#pragma mark - Connection

- (void)connectTo:(NSString *)pid {
    if (![self bluetoothReady] || [pid length] == 0) return;
    CBPeripheral *p = self.discovered[pid];
    if (!p) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:pid];
        if (uuid) p = [[self.centralManager retrievePeripheralsWithIdentifiers:@[uuid]] firstObject];
    }
    if (!p) {
        [self setStatus:@"تعذر العثور على الطابعة. ابحث مرة أخرى."];
        return;
    }
    if (self.printerPeripheral && self.printerPeripheral != p) {
        [self.centralManager cancelPeripheralConnection:self.printerPeripheral];
    }
    [self stopScan];
    self.printerPeripheral = p;
    self.printerPeripheral.delegate = self;
    self.writeCharacteristic = nil;
    self.printerName = p.name ?: @"طابعة";
    [self setStatus:[NSString stringWithFormat:@"جاري الاتصال بـ %@...", self.printerName]];
    [self pushPrinterState];
    [self.centralManager connectPeripheral:p options:nil];

    // connection timeout
    __weak AppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AppDelegate *s = weakSelf;
        if (s && s.printerPeripheral == p && !s.writeCharacteristic) {
            [s.centralManager cancelPeripheralConnection:p];
            s.printerPeripheral = nil;
            s.pendingPrintData = nil;
            [s setStatus:@"انتهت مهلة الاتصال. تأكد أن الطابعة مشغلة وغير متصلة بجهاز آخر."];
            [s pushPrinterState];
        }
    });
}

- (void)disconnect {
    if (self.printerPeripheral) [self.centralManager cancelPeripheralConnection:self.printerPeripheral];
    self.printerPeripheral = nil;
    self.writeCharacteristic = nil;
    self.sending = NO;
    self.pendingPrintData = nil;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:LAST_PRINTER_KEY];
    [self setStatus:@"تم قطع الاتصال بالطابعة."];
    [self pushPrinterState];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBCentralManagerStatePoweredOn) {
        [self setStatus:@"البلوتوث جاهز."];
        // Reconnect silently to the last used printer.
        NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:LAST_PRINTER_KEY];
        if (last && !self.printerPeripheral) [self connectTo:last];
    } else {
        self.scanning = NO;
        self.printerPeripheral = nil;
        self.writeCharacteristic = nil;
        self.sending = NO;
        [self call:@"onScanState" arg:@NO];
        [self setStatus:@"البلوتوث غير مفعل."];
    }
    [self pushPrinterState];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (peripheral != self.printerPeripheral) return;
    [self setStatus:@"تم الاتصال، جاري فحص قنوات الطباعة..."];
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral != self.printerPeripheral) return;
    self.printerPeripheral = nil;
    self.writeCharacteristic = nil;
    if (self.pendingPrintData) {
        self.pendingPrintData = nil;
        [self printDone:NO message:@"فشل الاتصال بالطابعة."];
    }
    [self setStatus:@"فشل الاتصال بالطابعة. حاول مرة أخرى."];
    [self pushPrinterState];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral != self.printerPeripheral) return;
    BOOL wasSending = self.sending;
    self.writeCharacteristic = nil;
    self.sending = NO;
    self.printerPeripheral = nil;
    if (wasSending) {
        self.pendingPrintData = nil;
        [self printDone:NO message:@"انقطع الاتصال بالطابعة أثناء الطباعة."];
    }
    [self setStatus:@"انقطع الاتصال بالطابعة."];
    [self pushPrinterState];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    BOOL found = NO;
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:CAT_SERVICE_UUID]]) {
            found = YES;
            [peripheral discoverCharacteristics:nil forService:service];
        }
    }
    if (!found) {
        [self setStatus:@"هذا الجهاز ليس طابعة Cat Printer مدعومة."];
        [self.centralManager cancelPeripheralConnection:peripheral];
        self.printerPeripheral = nil;
        if (self.pendingPrintData) {
            self.pendingPrintData = nil;
            [self printDone:NO message:@"الجهاز المختار ليس طابعة مدعومة."];
        }
        [self pushPrinterState];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:CAT_WRITE_UUID]]) {
            self.writeCharacteristic = characteristic;
        } else if (characteristic.properties & CBCharacteristicPropertyNotify) {
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
    }
    if (!self.writeCharacteristic) {
        [self setStatus:@"تعذر العثور على قناة الطباعة."];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:[self idOf:peripheral] forKey:LAST_PRINTER_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self setStatus:[NSString stringWithFormat:@"متصل بالطابعة %@ ✓", self.printerName]];
    [self pushPrinterState];
    if (self.pendingPrintData) [self beginSending];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    // Status notifications are ignored.
}

#pragma mark - Printing (non-blocking)

- (void)handlePrint:(NSString *)base64Data {
    if (self.sending) {
        [self printDone:NO message:@"الطابعة مشغولة بطباعة فاتورة أخرى، انتظر قليلاً."];
        return;
    }
    NSData *data = [base64Data length] ? [[NSData alloc] initWithBase64EncodedString:base64Data options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
    if ([data length] == 0) {
        [self printDone:NO message:@"تعذر قراءة بيانات الطباعة."];
        return;
    }
    if (self.printerPeripheral && self.writeCharacteristic && self.printerPeripheral.state == CBPeripheralStateConnected) {
        self.pendingPrintData = data;
        [self beginSending];
        return;
    }
    if (self.printerPeripheral) {          // connecting right now: print once ready
        self.pendingPrintData = data;
        return;
    }
    NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:LAST_PRINTER_KEY];
    if (last && [self bluetoothReady]) {
        self.pendingPrintData = data;
        [self connectTo:last];
        return;
    }
    [self printDone:NO message:@"لا توجد طابعة متصلة. اضغط «بحث عن الطابعات» واختر طابعتك أولاً."];
}

- (void)beginSending {
    if (!self.pendingPrintData || self.sending) return;
    self.sending = YES;
    self.sendOffset = 0;
    [self setStatus:@"جاري إرسال الفاتورة إلى الطابعة..."];
    [self sendNextChunks];
}

- (void)sendNextChunks {
    if (!self.sending) return;
    NSData *data = self.pendingPrintData;
    if (!self.printerPeripheral || !self.writeCharacteristic || !data) {
        self.sending = NO;
        return;
    }

    const NSUInteger chunkSize = 20;      // safe for every BLE MTU
    const NSUInteger chunksPerTick = 4;   // 80 bytes every ~20ms
    NSUInteger length = [data length];

    for (NSUInteger i = 0; i < chunksPerTick && self.sendOffset < length; i++) {
        NSUInteger n = MIN(chunkSize, length - self.sendOffset);
        NSData *chunk = [data subdataWithRange:NSMakeRange(self.sendOffset, n)];
        [self.printerPeripheral writeValue:chunk forCharacteristic:self.writeCharacteristic type:CBCharacteristicWriteWithoutResponse];
        self.sendOffset += n;
    }

    if (self.sendOffset < length) {
        if (self.sendOffset % 1600 < chunkSize * chunksPerTick) {
            [self call:@"onPrintProgress" arg:@((int)((self.sendOffset * 100) / length))];
        }
        __weak AppDelegate *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [weakSelf sendNextChunks];
        });
    } else {
        self.sending = NO;
        self.pendingPrintData = nil;
        [self printDone:YES message:@"تم إرسال الفاتورة إلى الطابعة بنجاح!"];
    }
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
