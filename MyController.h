/* MyController */

#import <Cocoa/Cocoa.h>
#import "MyView.h"

@interface MyController : NSDocumentController
{
    IBOutlet NSWindow* window;
    IBOutlet MyView* myView;
    IBOutlet NSMatrix* matrixSamplingRate;
    IBOutlet NSTextField* textTap;
    IBOutlet NSSlider* sliderTap;
    IBOutlet NSSlider* slider62Hz;
    IBOutlet NSSlider* slider125Hz;
    IBOutlet NSSlider* slider250Hz;
    IBOutlet NSSlider* slider500Hz;
    IBOutlet NSSlider* slider1kHz;
    IBOutlet NSSlider* slider2kHz;
    IBOutlet NSSlider* slider4kHz;
    IBOutlet NSSlider* slider8kHz;
    IBOutlet NSSlider* slider16kHz;
}
- (void)alert:(NSString*)message;
- (IBAction)orderFrontStandardAboutPanel:(id)sender;
- (IBAction)applyPreferences:(id)sender;
- (IBAction)resetEqualizer:(id)sender;
- (IBAction)resumePlayback:(id)sender;
- (IBAction)pausePlayback:(id)sender;
- (IBAction)rewindSequencer:(id)sender;
- (void)mouseDown:(float)value inElement:(const char*)element withModifiers:(unsigned int)modifiers;
- (void)mouseDragged:(float)value inElement:(const char*)element;
- (void)mouseUp:(float)value inElement:(const char*)element;
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender;
- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender;
- (void)draggingExited:(id <NSDraggingInfo>)sender;
- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender;
- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender;
- (void)concludeDragOperation:(id <NSDraggingInfo>)sender;
- (void)draggingEnded:(id <NSDraggingInfo>)sender;
@end
