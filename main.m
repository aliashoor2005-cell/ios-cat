#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate, UIWebViewDelegate, CBCentralManagerDelegate, CBPeripheralDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) UIWebView *webView;
@property (strong, nonatomic) CBCentralManager *centralManager;
@property (strong, nonatomic) CBPeripheral *printerPeripheral;
@property (strong, nonatomic) CBCharacteristic *writeCharacteristic;
@property (strong, nonatomic) NSData *pendingPrintData;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    UIViewController *vc = [[UIViewController alloc] init];
    self.webView = [[UIWebView alloc] initWithFrame:vc.view.bounds];
    self.webView.delegate = self;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:self.webView];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    if (htmlPath) {
        NSURL *htmlUrl = [NSURL fileURLWithPath:htmlPath];
        [self.webView loadRequest:[NSURLRequest requestWithURL:htmlUrl]];
    } else {
        [self.webView loadHTMLString:@"<h3 style='font-family:sans-serif;text-align:center;margin-top:40px;'>لم يتم العثور على ملف index.html داخل Resources</h3>" baseURL:nil];
    }

    self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    return YES;
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType {
    NSURL *url = [request URL];
    if ([[url scheme] isEqualToString:@"catprint"]) {
        NSString *base64Data = [url host];
        if (!base64Data || [base64Data length] == 0) {
            NSString *abs = [url absoluteString];
            NSRange r = [abs rangeOfString:@"://"];
            if (r.location != NSNotFound) {
                base64Data = [abs substringFromIndex:NSMaxRange(r)];
            }
        }
        if (base64Data && [base64Data length] > 0) {
            NSString *cleanBase64 = [base64Data stringByReplacingOccurrencesOfString:@" " withString:@"+"];
            self.pendingPrintData = [[NSData alloc] initWithBase64EncodedString:cleanBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (self.pendingPrintData && [self.pendingPrintData length] > 0) {
                [self startScanAndPrint];
            } else {
                [self.webView stringByEvaluatingJavaScriptFromString:@"alert('تعذر فك تشفير بيانات الطباعة.');"];
            }
        }
        return NO;
    }
    return YES;
}

- (void)startScanAndPrint {
    if (self.printerPeripheral && self.writeCharacteristic && self.printerPeripheral.state == CBPeripheralStateConnected) {
        [self sendDataInChunks:self.pendingPrintData];
    } else if (self.centralManager.state == CBCentralManagerStatePoweredOn) {
        [self.webView stringByEvaluatingJavaScriptFromString:@"setStatus('جاري البحث عن طابعة Cat Printer...');"];
        [self.centralManager scanForPeripheralsWithServices:nil options:nil];
    } else {
        [self.webView stringByEvaluatingJavaScriptFromString:@"setStatus('يرجى تشغيل البلوتوث في إعدادات الجهاز.');"];
    }
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBCentralManagerStatePoweredOn) {
        if (self.pendingPrintData) {
            [self.centralManager scanForPeripheralsWithServices:nil options:nil];
        } else {
            [self.webView stringByEvaluatingJavaScriptFromString:@"setStatus('البلوتوث جاهز.');"];
        }
    } else {
        [self.webView stringByEvaluatingJavaScriptFromString:@"setStatus('البلوتوث غير مفعل.');"];
    }
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI {
    NSString *name = peripheral.name ?: @"";
    if ([name hasPrefix:@"GB"] || [name hasPrefix:@"GT"] || [name hasPrefix:@"MX"] || [name containsString:@"Cat"] || [name containsString:@"Printer"]) {
        self.printerPeripheral = peripheral;
        self.printerPeripheral.delegate = self;
        [self.centralManager stopScan];
        [self.webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"setStatus('جاري الاتصال بـ %@...');", name]];
        [self.centralManager connectPeripheral:peripheral options:nil];
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    [self.webView stringByEvaluatingJavaScriptFromString:@"setStatus('تم الاتصال، جاري فحص قنوات الطباعة...');"];
    [peripheral discoverServices:@[[CBUUID UUIDWithString:@"AE30"]]];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    for (CBService *service in peripheral.services) {
        [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:@"AE01"]] forService:service];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:@"AE01"]]) {
            self.writeCharacteristic = characteristic;
            if (self.pendingPrintData) {
                [self sendDataInChunks:self.pendingPrintData];
            }
        }
    }
}

- (void)sendDataInChunks:(NSData *)data {
    if (!self.printerPeripheral || !self.writeCharacteristic) return;
    [self.webView stringByEvaluatingJavaScriptFromString:@"setStatus('جاري إرسال الفاتورة إلى الطابعة...');"];
    NSUInteger length = [data length];
    NSUInteger chunkSize = 20;
    for (NSUInteger offset = 0; offset < length; offset += chunkSize) {
        NSUInteger thisChunkSize = MIN(chunkSize, length - offset);
        NSData *chunk = [data subdataWithRange:NSMakeRange(offset, thisChunkSize)];
        [self.printerPeripheral writeValue:chunk forCharacteristic:self.writeCharacteristic type:CBCharacteristicWriteWithoutResponse];
        [NSThread sleepForTimeInterval:0.015];
    }
    self.pendingPrintData = nil;
    [self.webView stringByEvaluatingJavaScriptFromString:@"setStatus('تم إرسال الفاتورة بنجاح!');alert('تم إرسال الفاتورة إلى طابعة Cat Printer بنجاح!');"];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
