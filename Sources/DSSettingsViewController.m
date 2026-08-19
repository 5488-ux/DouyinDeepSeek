#import "DSSettingsViewController.h"
#import "DSConfig.h"
#import "DSDeepSeekClient.h"
#import "DSRuntimeBridge.h"
#import "DSConversationPickerViewController.h"

typedef NS_ENUM(NSInteger, DSSettingsSection) {
    DSSettingsSectionMaster,
    DSSettingsSectionAPI,
    DSSettingsSectionReply,
    DSSettingsSectionTest,
    DSSettingsSectionCount,
};

@interface DSSettingsViewController ()
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation DSSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DeepSeek 自动回复";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return DSSettingsSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case DSSettingsSectionMaster: return 2;
        case DSSettingsSectionAPI: return 5;
        case DSSettingsSectionReply: return 5;
        case DSSettingsSectionTest: return 4;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case DSSettingsSectionMaster: return @"总开关";
        case DSSettingsSectionAPI: return @"DeepSeek API";
        case DSSettingsSectionReply: return @"上下文与回复";
        case DSSettingsSectionTest: return @"测试与兼容性";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == DSSettingsSectionMaster) return @"首次看到一个会话时只记录最后消息，不会突然翻旧账自动回复。";
    if (section == DSSettingsSectionReply) return @"每条上下文都会明确标注“谁说的”。我的称呼代表账号主人；联系人名称自动取当前抖音昵称。图片、语音等非文本消息暂不送给模型。";
    if (section == DSSettingsSectionTest) return @"测试发话会在选中联系人后生成并交给抖音发信接口。请先打开目标聊天一次；接口调用成功后仍需回到聊天确认真实送达。";
    return nil;
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView style:(UITableViewCellStyle)style {
    return [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DSConfig *config = [DSConfig shared];
    UITableViewCell *cell = [self baseCellForTableView:tableView style:UITableViewCellStyleValue1];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.section == DSSettingsSectionMaster) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"启用自动回复";
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = config.enabled;
            [toggle addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text = @"工作状态";
            cell.detailTextLabel.text = config.enabled ? @"已开启" : @"已关闭";
            cell.detailTextLabel.textColor = config.enabled ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else if (indexPath.section == DSSettingsSectionAPI) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"API Key";
            cell.detailTextLabel.text = config.apiKey.length ? @"已安全保存" : @"未填写";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"API 地址";
            cell.detailTextLabel.text = config.baseURL;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"模型";
            cell.detailTextLabel.text = config.model;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"思考模式";
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = config.thinkingEnabled;
            [toggle addTarget:self action:@selector(thinkingChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text = @"最大回复 Token";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)config.maxReplyTokens];
        }
    } else if (indexPath.section == DSSettingsSectionReply) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"我的称呼";
            cell.detailTextLabel.text = config.ownerName;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"角色提示词";
            cell.detailTextLabel.text = @"点击编辑";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"上下文条数";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 条", (long)config.contextLimit];
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"同会话冷却";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f 秒", config.cooldown];
        } else {
            cell.textLabel.text = @"上下文规则";
            cell.detailTextLabel.text = @"每句标注：我的称呼/联系人昵称";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else if (indexPath.section == DSSettingsSectionTest) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"测试 DeepSeek API";
            cell.detailTextLabel.text = @"真实请求";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"测试发话";
            cell.detailTextLabel.text = @"选联系人→读上下文→生成→发送";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"复制运行报错";
            cell.detailTextLabel.text = @"发送路线、对象类型、异常记录";
        } else {
            cell.textLabel.text = @"Hook 兼容性";
            cell.detailTextLabel.text = [[DSRuntimeBridge shared] compatibilitySummary];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
    return cell;
}

- (void)enabledChanged:(UISwitch *)sender {
    [DSConfig shared].enabled = sender.isOn;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:DSSettingsSectionMaster] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)thinkingChanged:(UISwitch *)sender { [DSConfig shared].thinkingEnabled = sender.isOn; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == DSSettingsSectionAPI) {
        if (indexPath.row == 0) [self editAPIKey];
        else if (indexPath.row == 1) [self editTextSettingWithTitle:@"API 地址" value:[DSConfig shared].baseURL placeholder:@"https://api.deepseek.com/v1/chat/completions" secure:NO save:^(NSString *value) { [DSConfig shared].baseURL = value; }];
        else if (indexPath.row == 2) [self chooseModel];
        else if (indexPath.row == 4) [self editIntegerSettingWithTitle:@"最大回复 Token" value:[DSConfig shared].maxReplyTokens minimum:32 maximum:4096 save:^(NSInteger value) { [DSConfig shared].maxReplyTokens = value; }];
    } else if (indexPath.section == DSSettingsSectionReply) {
        if (indexPath.row == 0) [self editTextSettingWithTitle:@"我的称呼" value:[DSConfig shared].ownerName placeholder:@"例如：小明（留空则为“我”）" secure:NO save:^(NSString *value) { [DSConfig shared].ownerName = value; }];
        else if (indexPath.row == 1) [self editTextSettingWithTitle:@"角色提示词" value:[DSConfig shared].systemPrompt placeholder:@"告诉模型如何代替你回复" secure:NO save:^(NSString *value) { [DSConfig shared].systemPrompt = value; }];
        else if (indexPath.row == 2) [self editIntegerSettingWithTitle:@"上下文条数" value:[DSConfig shared].contextLimit minimum:2 maximum:100 save:^(NSInteger value) { [DSConfig shared].contextLimit = value; }];
        else if (indexPath.row == 3) [self editIntegerSettingWithTitle:@"同会话冷却秒数" value:(NSInteger)[DSConfig shared].cooldown minimum:0 maximum:3600 save:^(NSInteger value) { [DSConfig shared].cooldown = value; }];
    } else if (indexPath.section == DSSettingsSectionTest) {
        if (indexPath.row == 0) [self testAPI];
        else if (indexPath.row == 1) [self chooseConversationForTest];
        else if (indexPath.row == 2) [self showDiagnosticForConversation:nil];
    }
}

- (void)editAPIKey {
    [self editTextSettingWithTitle:@"DeepSeek API Key" value:[DSConfig shared].apiKey ?: @"" placeholder:@"sk-..." secure:YES save:^(NSString *value) {
        [DSConfig shared].apiKey = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }];
}

- (void)chooseModel {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择模型" message:@"V4 Flash 更快更便宜，V4 Pro 更强但更慢。" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *model in @[@"deepseek-v4-flash", @"deepseek-v4-pro"]) {
        [sheet addAction:[UIAlertAction actionWithTitle:model style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [DSConfig shared].model = model;
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)editTextSettingWithTitle:(NSString *)title value:(NSString *)value placeholder:(NSString *)placeholder secure:(BOOL)secure save:(void (^)(NSString *value))save {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = value;
        field.placeholder = placeholder;
        field.secureTextEntry = secure;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        save(alert.textFields.firstObject.text ?: @"");
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editIntegerSettingWithTitle:(NSString *)title value:(NSInteger)value minimum:(NSInteger)minimum maximum:(NSInteger)maximum save:(void (^)(NSInteger value))save {
    [self editTextSettingWithTitle:title value:[NSString stringWithFormat:@"%ld", (long)value] placeholder:nil secure:NO save:^(NSString *raw) {
        NSInteger parsed = raw.integerValue;
        save(MAX(minimum, MIN(maximum, parsed)));
    }];
}

- (void)testAPI {
    [self setBusy:YES title:@"正在测试 API…"];
    [[DSDeepSeekClient shared] testConnection:^(NSString *reply, NSError *error) {
        [self setBusy:NO title:nil];
        [self showResultTitle:error ? @"API 测试失败" : @"API 测试成功" message:error.localizedDescription ?: reply];
    }];
}

- (void)chooseConversationForTest {
    __weak typeof(self) weakSelf = self;
    DSConversationPickerViewController *picker = [[DSConversationPickerViewController alloc] initWithSelectionHandler:^(DSConversationSnapshot *conversation) {
        [weakSelf.navigationController popViewControllerAnimated:YES];
        [weakSelf runTestForConversation:conversation];
    }];
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)runTestForConversation:(DSConversationSnapshot *)conversation {
    NSArray *messages = [[DSRuntimeBridge shared] apiMessagesForConversation:conversation];
    if (!conversation.messages.count) {
        [self showResultTitle:@"没有上下文" message:@"先打开这个人的聊天，等消息显示出来，再回来点测试发话。不能没上下文硬生成。"];
        return;
    }
    [self setBusy:YES title:[NSString stringWithFormat:@"正在结合 %@ 的上下文生成…", conversation.displayName]];
    [[DSDeepSeekClient shared] generateReplyWithMessages:messages conversationID:conversation.conversationID completion:^(NSString *reply, NSError *error) {
        if (error) {
            [self setBusy:NO title:nil];
            [self showResultTitle:@"生成失败" message:error.localizedDescription];
            return;
        }
        [[DSRuntimeBridge shared] sendText:reply toConversation:conversation completion:^(BOOL success, NSError *sendError) {
            [self setBusy:NO title:nil];
            NSString *title = success ? @"已确认消息出现在会话中" : @"生成成功，但真实发信失败";
            NSString *message = success ? [NSString stringWithFormat:@"目标：%@\n\n%@", conversation.displayName, reply] : [NSString stringWithFormat:@"已生成：%@\n\n发信错误：%@\n\n点下面的“复制报错”，把完整内容发给开发者。", reply, sendError.localizedDescription];
            NSString *report = success ? nil : [[DSRuntimeBridge shared] diagnosticReportForConversation:conversation];
            [self showResultTitle:title message:message copyText:report];
        }];
    }];
}

- (void)showDiagnosticForConversation:(DSConversationSnapshot *)conversation {
    DSConversationSnapshot *target = conversation ?: [DSRuntimeBridge shared].knownConversations.firstObject;
    NSString *report = [[DSRuntimeBridge shared] diagnosticReportForConversation:target];
    NSString *message = target
        ? [NSString stringWithFormat:@"已生成 %@ 的完整运行报错。点击“复制报错”后直接发给开发者。", target.displayName]
        : @"当前还没有捕获到会话，但仍可复制 Hook 和运行环境报错。先打开一个聊天再测试，信息会更完整。";
    [self showResultTitle:@"运行报错" message:message copyText:report];
}

- (void)setBusy:(BOOL)busy title:(NSString *)title {
    self.view.userInteractionEnabled = !busy;
    if (busy) {
        [self.spinner startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
        self.navigationItem.prompt = title;
    } else {
        [self.spinner stopAnimating];
        self.navigationItem.rightBarButtonItem = nil;
        self.navigationItem.prompt = nil;
    }
}

- (void)showResultTitle:(NSString *)title message:(NSString *)message {
    [self showResultTitle:title message:message copyText:nil];
}

- (void)showResultTitle:(NSString *)title message:(NSString *)message copyText:(NSString *)copyText {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (copyText.length) {
        [alert addAction:[UIAlertAction actionWithTitle:@"复制报错" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = copyText;
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
