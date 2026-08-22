#import "DSAISendLogViewController.h"
#import "DSRuntimeBridge.h"

@interface DSAISendLogViewController ()
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *records;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@end

@implementation DSAISendLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"AI发送记录";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.dateFormatter = [[NSDateFormatter alloc] init];
    self.dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    self.dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"操作"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(showActions)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRecords];
}

- (void)reloadRecords {
    self.records = [[DSRuntimeBridge shared] aiSendRecords];
    [self.tableView reloadData];
    if (!self.records.count) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, 0, self.view.bounds.size.width - 48, 220)];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.secondaryLabelColor;
        label.text = @"暂无记录\n\nAI生成并交给发信链的正文会保存在这里；聊天里不会添加任何“AI自动发送”字样。";
        self.tableView.backgroundView = label;
    } else {
        self.tableView.backgroundView = nil;
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.records.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *record = self.records[indexPath.row];
    NSString *target = [record[@"displayName"] isKindOfClass:NSString.class] ? record[@"displayName"] : @"未知会话";
    NSString *source = [record[@"source"] isKindOfClass:NSString.class] ? record[@"source"] : @"AI发送";
    NSString *status = [record[@"status"] isKindOfClass:NSString.class] ? record[@"status"] : @"未知状态";
    NSString *text = [record[@"text"] isKindOfClass:NSString.class] ? record[@"text"] : @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[record[@"createdAt"] doubleValue]];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", target, source];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@", [self.dateFormatter stringFromDate:date], status, text];
    cell.detailTextLabel.numberOfLines = 3;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if ([status isEqualToString:@"发送成功"]) cell.detailTextLabel.textColor = UIColor.systemGreenColor;
    else if ([status isEqualToString:@"发送失败"]) cell.detailTextLabel.textColor = UIColor.systemRedColor;
    else cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (NSString *)detailTextForRecord:(NSDictionary *)record {
    NSDate *created = [NSDate dateWithTimeIntervalSince1970:[record[@"createdAt"] doubleValue]];
    NSMutableString *detail = [NSMutableString string];
    [detail appendString:@"记录类型：AI生成发送审计\n"];
    [detail appendFormat:@"触发方式：%@\n", record[@"source"] ?: @"未知"];
    [detail appendFormat:@"时间：%@\n", [self.dateFormatter stringFromDate:created]];
    [detail appendFormat:@"会话类型：%@\n", record[@"conversationType"] ?: @"未知"];
    [detail appendFormat:@"目标：%@\n", record[@"displayName"] ?: @"未知"];
    [detail appendFormat:@"会话ID：%@\n", record[@"conversationID"] ?: @"未知"];
    [detail appendFormat:@"状态：%@\n", record[@"status"] ?: @"未知"];
    if ([record[@"error"] length]) [detail appendFormat:@"错误：%@\n", record[@"error"]];
    [detail appendFormat:@"操作ID：%@\n\nAI正文：\n%@", record[@"operationID"] ?: @"未知", record[@"text"] ?: @""];
    return detail;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *detail = [self detailTextForRecord:self.records[indexPath.row]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AI发送详情" message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制记录" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = detail;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)allRecordsText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *record in self.records) [parts addObject:[self detailTextForRecord:record]];
    return [parts componentsJoinedByString:@"\n\n--------------------\n\n"];
}

- (void)showActions {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"AI发送记录"
                                                                   message:@"记录只保存在本机，不会写进聊天正文。"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (self.records.count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"复制全部记录" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = [self allRecordsText];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"清空全部记录" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [self confirmClear];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), 44, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmClear {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空全部记录？"
                                                                   message:@"清空后无法恢复。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[DSRuntimeBridge shared] clearAISendRecords];
        [self reloadRecords];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
