#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>

// Cat Printer (GB01/GB02/GB03/GT01/MX...) BLE: service AE30 (some models AF30),
// write characteristic AE01, notify characteristic AE02 — same as the Android app.
#define CAT_WRITE_UUID   @"AE01"
#define LAST_PRINTER_KEY @"lastPrinterId"

// JS <-> native bridge
//   JS -> native: the page queues commands in window.__nativeQueue and loads
//                 catprint://flush; native pulls them with __flushNativeQueue().
//                 Commands: scan, stopScan, connect(id), disconnect, print(data),
//                 state, save(key,value), pickImage(target), theme(dark)
//   native -> JS: onScanState(bool), onDeviceFound({...}), onPrinterState({...}),
//                 onNative({code, level, name, count}), onPrintProgress(percent),
//                 onPrintDone({ok, code}), onImagePicked({target, data})
//   Messages are sent as codes so the page can show them in its own language.
//   Persistent data lives in Documents/store_<key>.json and is injected into
//   the page as window.__nativeStore before any page script runs.

@interface AppDelegate : UIResponder <UIApplicationDelegate, UIWebViewDelegate, CBCentralManagerDelegate, CBPeripheralDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) UIViewController *rootVC;
@property (strong, nonatomic) UIWebView *webView;
@property (strong, nonatomic) CBCentralManager *centralManager;
@property (strong, nonatomic) NSMutableDictionary *discovered;   // id -> CBPeripheral
@property (strong, nonatomic) CBPeripheral *printerPeripheral;
@property (strong, nonatomic) CBCharacteristic *writeCharacteristic;
@property (strong, nonatomic) NSString *printerName;
@property (strong, nonatomic) NSData *pendingPrintData;
@property (strong, nonatomic) NSString *pickTarget;
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

// level: info | ok | wait | error
- (void)notify:(NSString *)code level:(NSString *)level extra:(NSDictionary *)extra {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
    d[@"code"] = code;
    d[@"level"] = level;
    [self call:@"onNative" arg:d];
}

- (void)notify:(NSString *)code level:(NSString *)level {
    [self notify:code level:level extra:nil];
}

- (void)printDone:(BOOL)ok code:(NSString *)code {
    [self call:@"onPrintDone" arg:@{@"ok": @(ok), @"code": code}];
}

- (NSString *)idOf:(CBPeripheral *)p {
    return [p.identifier UUIDString];
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

#pragma mark - Persistent store

- (NSString *)storeDir {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

- (NSString *)storePathFor:(NSString *)key {
    // keys come from the page: keep them to a safe file name
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *safe = [[key componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    return [[self storeDir] stringByAppendingPathComponent:[NSString stringWithFormat:@"store_%@.json", safe]];
}

- (void)saveKey:(NSString *)key value:(NSString *)value {
    if (![key isKindOfClass:[NSString class]] || [key length] == 0) return;
    if (![value isKindOfClass:[NSString class]]) value = @"";
    [value writeToFile:[self storePathFor:key] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)storeScript {
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self storeDir] error:nil];
    for (NSString *f in files) {
        if (![f hasPrefix:@"store_"] || ![f hasSuffix:@".json"]) continue;
        NSString *key = [f substringWithRange:NSMakeRange(6, [f length] - 11)];
        NSString *v = [NSString stringWithContentsOfFile:[[self storeDir] stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
        if (v) all[key] = v;
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:all options:0 error:nil];
    NSString *js = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
    js = [js stringByReplacingOccurrencesOfString:@"</" withString:@"<\\/"];
    return [NSString stringWithFormat:@"<script>window.__isNative=true;window.__nativeStore=%@;</script>", js];
}

#pragma mark - App

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.discovered = [NSMutableDictionary dictionary];
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    UIColor *bg = [UIColor colorWithRed:0.067 green:0.067 blue:0.067 alpha:1.0];
    self.window.backgroundColor = bg;
    self.rootVC = [[UIViewController alloc] init];
    self.rootVC.view.backgroundColor = bg;

    CGRect frame = self.rootVC.view.bounds;
    frame.origin.y += 20.0;
    frame.size.height -= 20.0;
    self.webView = [[UIWebView alloc] initWithFrame:frame];
    self.webView.delegate = self;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = bg;
    self.webView.opaque = NO;
    self.webView.scrollView.bounces = NO;
    [self.rootVC.view addSubview:self.webView];
    self.window.rootViewController = self.rootVC;
    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:UIStatusBarStyleLightContent];

    NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    NSString *html = htmlPath ? [NSString stringWithContentsOfFile:htmlPath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (html) {
        html = [html stringByReplacingOccurrencesOfString:@"<!--NATIVE_STORE-->" withString:[self storeScript]];
        // loadHTMLString avoids a static reference to NSURLRequest, whose home
        // framework differs between iOS 8 (Foundation) and iOS 9+ (CFNetwork).
        NSURL *baseUrl = [NSURL fileURLWithPath:[htmlPath stringByDeletingLastPathComponent] isDirectory:YES];
        [self.webView loadHTMLString:html baseURL:baseUrl];
    } else {
        [self.webView loadHTMLString:@"<h3 style='font-family:sans-serif;text-align:center;margin-top:40px;color:#fff'>index.html missing</h3>" baseURL:nil];
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
        else if ([cmd isEqualToString:@"save"]) [self saveKey:c[@"key"] value:c[@"value"]];
        else if ([cmd isEqualToString:@"pickImage"]) [self pickImage:c[@"target"]];
        else if ([cmd isEqualToString:@"theme"]) [self applyTheme:[c[@"dark"] boolValue]];
    }
}

- (void)applyTheme:(BOOL)dark {
    UIColor *bg = dark ? [UIColor colorWithRed:0.067 green:0.067 blue:0.067 alpha:1.0]
                       : [UIColor colorWithRed:0.953 green:0.957 blue:0.965 alpha:1.0];
    self.window.backgroundColor = bg;
    self.rootVC.view.backgroundColor = bg;
    self.webView.backgroundColor = bg;
    [[UIApplication sharedApplication] setStatusBarStyle:dark ? UIStatusBarStyleLightContent : UIStatusBarStyleDefault animated:YES];
}

#pragma mark - Photo picker

- (void)pickImage:(NSString *)target {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        [self notify:@"no_photos" level:@"error"];
        return;
    }
    self.pickTarget = [target isKindOfClass:[NSString class]] ? target : @"";
    UIImagePickerController *pc = [[UIImagePickerController alloc] init];
    pc.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    pc.delegate = self;
    // On iPad the photo library must be shown as a popover (iOS 8 API);
    // on iPhone the popover style adapts to full screen.
    pc.modalPresentationStyle = UIModalPresentationPopover;
    UIPopoverPresentationController *pop = pc.popoverPresentationController;
    if (pop) {
        UIView *v = self.rootVC.view;
        pop.sourceView = v;
        pop.sourceRect = CGRectMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds) / 2, 1, 1);
        pop.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self.rootVC presentViewController:pc animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    NSString *target = self.pickTarget ?: @"";
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!img) return;

    // Resize (and bake in the EXIF orientation) so pictures stay small.
    CGFloat maxSide = [target isEqualToString:@"logo"] ? 384.0 : 260.0;
    CGSize s = img.size;
    CGFloat scale = MIN(1.0, maxSide / MAX(s.width, s.height));
    CGSize ns = CGSizeMake(floor(s.width * scale), floor(s.height * scale));
    UIGraphicsBeginImageContextWithOptions(ns, YES, 1.0);
    [[UIColor whiteColor] setFill];
    UIRectFill(CGRectMake(0, 0, ns.width, ns.height));
    [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    NSData *jpg = UIImageJPEGRepresentation(out, 0.8);
    NSString *dataUrl = [@"data:image/jpeg;base64," stringByAppendingString:[jpg base64EncodedStringWithOptions:0]];
    [self call:@"onImagePicked" arg:@{@"target": target, @"data": dataUrl}];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Scanning

- (BOOL)bluetoothReady {
    switch (self.centralManager.state) {
        case CBCentralManagerStatePoweredOn: return YES;
        case CBCentralManagerStateUnsupported: [self notify:@"bt_unsupported" level:@"error"]; break;
        case CBCentralManagerStateUnauthorized: [self notify:@"bt_unauthorized" level:@"error"]; break;
        case CBCentralManagerStateUnknown:
        case CBCentralManagerStateResetting: [self notify:@"bt_init" level:@"wait"]; break;
        default: [self notify:@"bt_off" level:@"error"]; break;
    }
    return NO;
}

- (void)startScan {
    if (![self bluetoothReady]) { [self call:@"onScanState" arg:@NO]; return; }
    if (self.scanning) [self.centralManager stopScan];
    self.scanning = YES;
    [self.discovered removeAllObjects];
    if (self.printerPeripheral) self.discovered[[self idOf:self.printerPeripheral]] = self.printerPeripheral;
    [self call:@"onScanState" arg:@YES];
    [self notify:@"scanning" level:@"wait"];

    // A printer already connected to this device (by another app, or earlier)
    // stops advertising, so a scan alone never finds it.
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
            if ([s.discovered count]) [s notify:@"scan_done" level:@"info" extra:@{@"count": @([s.discovered count])}];
            else [s notify:@"scan_none" level:@"error"];
        }
    });
}

- (void)stopScan {
    if (self.scanning) [self.centralManager stopScan];
    self.scanning = NO;
    [self call:@"onScanState" arg:@NO];
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

- (BOOL)looksLikeCatPrinter:(NSString *)name advertisement:(NSDictionary *)adv {
    NSArray *uuids = adv[CBAdvertisementDataServiceUUIDsKey];
    for (CBUUID *u in uuids) {
        NSString *s = [[u UUIDString] uppercaseString];
        if ([s isEqualToString:@"AE30"] || [s isEqualToString:@"AF30"]) return YES;
    }
    if ([name length] == 0) return NO;
    // same name rules as isLikelyPrinter() in the Android app
    NSString *u = [name uppercaseString];
    for (NSString *token in @[@"GT", @"GB", @"MX", @"PRINT", @"CAT", @"LABEL", @"THERMAL"]) {
        if ([u rangeOfString:token].location != NSNotFound) return YES;
    }
    return NO;
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI {
    NSString *name = advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name;
    [self reportPeripheral:peripheral name:name rssi:[RSSI integerValue]
                    likely:[self looksLikeCatPrinter:name advertisement:advertisementData]];
}

#pragma mark - Connection

- (void)connectTo:(NSString *)pid {
    if (![self bluetoothReady] || ![pid isKindOfClass:[NSString class]] || [pid length] == 0) return;
    CBPeripheral *p = self.discovered[pid];
    if (!p) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:pid];
        if (uuid) p = [[self.centralManager retrievePeripheralsWithIdentifiers:@[uuid]] firstObject];
    }
    if (!p) {
        [self notify:@"not_found_again" level:@"error"];
        return;
    }
    if (self.printerPeripheral && self.printerPeripheral != p) {
        [self.centralManager cancelPeripheralConnection:self.printerPeripheral];
    }
    [self stopScan];
    self.printerPeripheral = p;
    self.printerPeripheral.delegate = self;
    self.writeCharacteristic = nil;
    self.printerName = [p.name length] ? p.name : @"Printer";
    [self notify:@"connecting" level:@"wait" extra:@{@"name": self.printerName}];
    [self pushPrinterState];
    [self.centralManager connectPeripheral:p options:nil];

    __weak AppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AppDelegate *s = weakSelf;
        if (s && s.printerPeripheral == p && !s.writeCharacteristic) {
            [s.centralManager cancelPeripheralConnection:p];
            s.printerPeripheral = nil;
            if (s.pendingPrintData) {
                s.pendingPrintData = nil;
                [s printDone:NO code:@"conn_timeout"];
            }
            [s notify:@"conn_timeout" level:@"error"];
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
    [self notify:@"disconnected" level:@"info"];
    [self pushPrinterState];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBCentralManagerStatePoweredOn) {
        [self notify:@"bt_ready" level:@"ok"];
        NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:LAST_PRINTER_KEY];
        if (last && !self.printerPeripheral) [self connectTo:last];
    } else {
        self.scanning = NO;
        self.printerPeripheral = nil;
        self.writeCharacteristic = nil;
        self.sending = NO;
        [self call:@"onScanState" arg:@NO];
        if (central.state == CBCentralManagerStatePoweredOff) [self notify:@"bt_off" level:@"error"];
    }
    [self pushPrinterState];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (peripheral != self.printerPeripheral) return;
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral != self.printerPeripheral) return;
    self.printerPeripheral = nil;
    self.writeCharacteristic = nil;
    if (self.pendingPrintData) {
        self.pendingPrintData = nil;
        [self printDone:NO code:@"conn_failed"];
    }
    [self notify:@"conn_failed" level:@"error"];
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
        [self printDone:NO code:@"conn_lost_printing"];
    }
    [self notify:@"conn_lost" level:@"error"];
    [self pushPrinterState];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    BOOL found = NO;
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:@"AE30"]] || [service.UUID isEqual:[CBUUID UUIDWithString:@"AF30"]]) {
            found = YES;
            [peripheral discoverCharacteristics:nil forService:service];
        }
    }
    if (!found) {
        [self.centralManager cancelPeripheralConnection:peripheral];
        self.printerPeripheral = nil;
        if (self.pendingPrintData) {
            self.pendingPrintData = nil;
            [self printDone:NO code:@"not_printer"];
        }
        [self notify:@"not_printer" level:@"error"];
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
        [self notify:@"no_channel" level:@"error"];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:[self idOf:peripheral] forKey:LAST_PRINTER_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self notify:@"connected" level:@"ok" extra:@{@"name": self.printerName ?: @""}];
    [self pushPrinterState];
    if (self.pendingPrintData) [self beginSending];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    // Status notifications are ignored.
}

#pragma mark - Printing (non-blocking)

- (void)handlePrint:(NSString *)base64Data {
    if (self.sending) { [self printDone:NO code:@"print_busy"]; return; }
    NSData *data = ([base64Data isKindOfClass:[NSString class]] && [base64Data length])
        ? [[NSData alloc] initWithBase64EncodedString:base64Data options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
    if ([data length] == 0) { [self printDone:NO code:@"print_bad_data"]; return; }

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
    [self printDone:NO code:@"no_printer"];
}

- (void)beginSending {
    if (!self.pendingPrintData || self.sending) return;
    self.sending = YES;
    self.sendOffset = 0;
    [self notify:@"sending" level:@"wait"];
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
        [self printDone:YES code:@"print_ok"];
    }
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
