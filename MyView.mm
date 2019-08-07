#import "MyView.h"
#import "MyController.h"

#include <cmath>
#include <cstdio>
#include <utility>

static void read_ui_elements(std::map<std::string, ui_element_t>& elements, float height)
{
    NSString* filename = [[NSBundle mainBundle] pathForResource:@"skin" ofType:@"txt"];
    std::FILE* fp = std::fopen([filename lossyCString], "rb");
    if(fp){
        int c;
        while((c = std::getc(fp)) != EOF){
            if(c == '@'){
                char name[64];
                int x, y, w, h;
                if(fscanf(fp, "%s%d%d%d%d", name, &x, &y, &w, &h) == 5){
                    ui_element_t& element = elements[name];
                    element.name = name;
                    if(std::strcmp(name, "text") == 0){
                        element.rect = NSMakeRect(x, y, w, h);
                    }else{
                        element.rect = NSMakeRect(x, height - y - h, w, h);
                    }
                }
            }
        }
        std::fclose(fp);
    }
}
static void drawElement(ui_element_t& element, NSImage* skin1, NSImage* skin2, NSDictionary* textAttr)
{
    element.dirty = false;
    [skin1 drawInRect:element.rect
             fromRect:element.rect
            operation:NSCompositeCopy
             fraction:1];
    float zero = (element.type == UI_HORIZONTAL_CENTER ? 0.5 : 0);
    if(element.value != zero){
        float value = std::min(1.0f, element.value);
        NSRect rect;
        switch(element.type){
            case UI_VERTICAL:
                rect = NSMakeRect(element.rect.origin.x, element.rect.origin.y, element.rect.size.width, std::floor(element.rect.size.height * element.value));
                break;
            case UI_HORIZONTAL_CENTER:
                if(value < 0.5){
                    float x = element.rect.size.width * element.value;
                    rect = NSMakeRect(element.rect.origin.x + x, element.rect.origin.y, element.rect.size.width / 2 - x, element.rect.size.height);
                }else{
                    float x = element.rect.size.width / 2;
                    rect = NSMakeRect(element.rect.origin.x + x, element.rect.origin.y, element.rect.size.width * element.value - x, element.rect.size.height);
                }
                break;
            case UI_HORIZONTAL:
            default:
                rect = NSMakeRect(element.rect.origin.x, element.rect.origin.y, element.rect.size.width * element.value, element.rect.size.height);
                break;
        }
        [skin2 drawInRect:rect
                 fromRect:rect
                operation:NSCompositeCopy
                 fraction:1];
    }
    if(!element.s.empty()){
        NSString* s = [[NSString alloc] initWithCString:element.s.c_str()];
        [s drawInRect:element.rect withAttributes:textAttr];
        [s release];
    }
}

@implementation MyView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if(self){
        skin1 = [[NSImage imageNamed:@"skin-a.tiff"] retain];
        skin2 = [[NSImage imageNamed:@"skin-b.tiff"] retain];
        if(skin1 && skin2){
            try{
                elements = new std::map<std::string, ui_element_t>();
                read_ui_elements(*elements, [skin1 size].height);
                NSRect& r = (*elements)["text"].rect;
                float fontSize = r.size.height;
                NSFont* font = [NSFont userFontOfSize:fontSize];
                NSLayoutManager *lm = [[NSLayoutManager alloc] init];
                fontSize *= fontSize / [lm defaultLineHeightForFont:font];
                [lm release];
                font = [NSFont userFontOfSize:fontSize];
                NSColor* color = [NSColor colorWithCalibratedRed:r.origin.x / 255.0
                                                           green:r.origin.y / 255.0
                                                            blue:r.size.width / 255.0
                                                           alpha:1];
                if(font && color){
                    textAttr = [[NSDictionary alloc] initWithObjects:[NSArray arrayWithObjects:font, color, nil]
                                                             forKeys:[NSArray arrayWithObjects:NSFontAttributeName, NSForegroundColorAttributeName, nil]];
                    if(textAttr){
                        return self;
                    }
                }
            }catch(...){
            }
        }
        [self release];
    }
    return nil;
}
- (void)dealloc
{
    delete elements;
    [skin1 release];
    [skin2 release];
    [textAttr release];
    [super dealloc];
}

- (void)drawRect:(NSRect)bounds
{
    dirty = true;
    [skin1 drawInRect:bounds
             fromRect:bounds
            operation:NSCompositeCopy
             fraction:1];
    std::map<std::string, ui_element_t>::iterator i, end = elements->end();
    for(i = elements->begin(); i != end; ++i){
        ui_element_t& element = i->second;
        if(NSIntersectsRect(bounds, element.rect)){
            drawElement(element, nil, skin2, textAttr);
        }
    }
}

- (BOOL)isOpaque
{
    return YES;
}

- (NSSize)preferredSize
{
    return [skin1 size];
}

- (void)setValue:(float)value forKey:(const char*)key type:(ui_element_type_t)type
{
    ui_element_t& element = (*elements)[key];
    if(element.value != value){
        element.value = value;
        element.type = type;
        element.dirty = true;
        dirty = true;
    }
}

- (void)setText:(const char*)s forKey:(const char*)key
{
    ui_element_t& element = (*elements)[key];
    if(element.s != s){
        element.s = s;
        element.dirty = true;
        dirty = true;
    }
}

- (void)updateElements
{
    if(dirty){
        dirty = false;
        if([self lockFocusIfCanDraw]){
            std::map<std::string, ui_element_t>::iterator i, end = elements->end();
            for(i = elements->begin(); i != end; ++i){
                ui_element_t& element = i->second;
                if(element.dirty){
                    drawElement(element, skin1, skin2, textAttr);
                }
            }
            [self unlockFocus];
            [[self window] flushWindow];
        }
    }
}

- (ui_element_t*)findElementAt:(NSPoint)p
{
    std::map<std::string, ui_element_t>::iterator i, end = elements->end();
    for(i = elements->begin(); i != end; ++i){
        if(NSPointInRect(p, i->second.rect)){
            return &i->second;
        }
    }
    return NULL;
}

- (void)mouseDown:(NSEvent*)theEvent
{
    NSPoint p = [self convertPoint:[theEvent locationInWindow] fromView:nil];
    focusElement = [self findElementAt:p];
    if(focusElement){
        float value = (p.x - focusElement->rect.origin.x) / focusElement->rect.size.width;
        value = std::max(0.0f, std::min(1.0f, value));
        [controller mouseDown:value inElement:focusElement->name.c_str() withModifiers:[theEvent modifierFlags]];
    }
}
- (void)mouseDragged:(NSEvent *)theEvent
{
    if(focusElement){
        NSPoint p = [self convertPoint:[theEvent locationInWindow] fromView:nil];
        float value = (p.x - focusElement->rect.origin.x) / focusElement->rect.size.width;
        value = std::max(0.0f, std::min(1.0f, value));
        [controller mouseDragged:value inElement:focusElement->name.c_str()];
    }
}
- (void)mouseUp:(NSEvent *)theEvent
{
    if(focusElement){
        NSPoint p = [self convertPoint:[theEvent locationInWindow] fromView:nil];
        float value = (p.x - focusElement->rect.origin.x) / focusElement->rect.size.width;
        value = std::max(0.0f, std::min(1.0f, value));
        [controller mouseUp:value inElement:focusElement->name.c_str()];
        focusElement = NULL;
    }
}

@end
