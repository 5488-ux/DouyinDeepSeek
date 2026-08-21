#import "DSConversationPickerViewController.h"

@interface DSConversationPickerViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) DSConversationPickHandler selectionHandler;
@property (nonatomic, copy) NSArray<DSConversationSnapshot *> *allConversations;
@property (nonatomic, copy) NSArray<DSConversationSnapshot *> *visibleConversations;
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation DSConversationPickerViewController

- (instancetype)initWithSelectionHandler:(DSConversationPickHandler)selectionHandler {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _selectionHandler = [selectionHandler copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择测试会话";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"conversation"];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索私聊、群聊或会话 ID";
    self.navigationItem.searchController = self.searchController;
    self.definesPresentationContext = YES;
    [self reloadConversations];
}

- (void)reloadConversations {
    self.allConversations = [[DSRuntimeBridge shared] knownConversations];
    self.visibleConversations = self.allConversations;
    [self.tableView reloadData];

    if (!self.allConversations.count) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, 0, self.view.bounds.size.width - 48, 180)];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.secondaryLabelColor;
        label.text = @"还没抓到会话。先收到一条私聊或群聊消息，也可以打开目标会话让插件读取上下文，再回来测试。";
        self.tableView.backgroundView = label;
    } else {
        self.tableView.backgroundView = nil;
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) {
        self.visibleConversations = self.allConversations;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(DSConversationSnapshot *item, NSDictionary *bindings) {
            return [item.displayName localizedCaseInsensitiveContainsString:query] ||
                   [item.conversationID localizedCaseInsensitiveContainsString:query];
        }];
        self.visibleConversations = [self.allConversations filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.visibleConversations.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"conversation" forIndexPath:indexPath];
    DSConversationSnapshot *conversation = self.visibleConversations[indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    NSString *type = conversation.groupConversation ? @"群聊" : (conversation.directConversation ? @"私聊" : @"未识别");
    content.text = [NSString stringWithFormat:@"[%@] %@", type, conversation.displayName.length ? conversation.displayName : @"未命名会话"];
    DSMessageSnapshot *last = conversation.messages.lastObject;
    content.secondaryText = last.text.length ? last.text : [@"会话 ID：" stringByAppendingString:conversation.conversationID];
    content.secondaryTextProperties.numberOfLines = 2;
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    DSConversationSnapshot *conversation = self.visibleConversations[indexPath.row];
    if (self.selectionHandler) self.selectionHandler(conversation);
}

@end
