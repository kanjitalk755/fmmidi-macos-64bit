/* MyView */

#import <Cocoa/Cocoa.h>
#include <map>
#include <string>

enum ui_element_type_t{
    UI_HORIZONTAL,
    UI_HORIZONTAL_CENTER,
    UI_VERTICAL
};

struct ui_element_t{
    NSRect rect;
    std::string name;
    std::string s;
    float value;
    ui_element_type_t type;
    bool dirty;

    ui_element_t():rect(NSMakeRect(0,0,0,0)),value(0){}
};

@interface MyView : NSView
{
    IBOutlet id controller;
    NSImage* skin1;
    NSImage* skin2;
    NSDictionary* textAttr;
    std::map<std::string, ui_element_t>* elements;
    ui_element_t* focusElement;
    bool dirty;
}
- (NSSize)preferredSize;
- (void)setValue:(float)value forKey:(const char*)key type:(ui_element_type_t)type;
- (void)setText:(const char*)s forKey:(const char*)key;
- (void)updateElements;
@end
