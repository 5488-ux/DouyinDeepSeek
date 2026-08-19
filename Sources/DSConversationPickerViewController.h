#import <UIKit/UIKit.h>
#import "DSRuntimeBridge.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^DSConversationPickHandler)(DSConversationSnapshot *conversation);

@interface DSConversationPickerViewController : UITableViewController
- (instancetype)initWithSelectionHandler:(DSConversationPickHandler)selectionHandler;
@end

NS_ASSUME_NONNULL_END

