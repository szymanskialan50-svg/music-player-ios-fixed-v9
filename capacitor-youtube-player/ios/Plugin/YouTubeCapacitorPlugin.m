#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

// Define the plugin using the CAP_PLUGIN Macro, and
// each method the plugin supports using the CAP_PLUGIN_METHOD macro.
CAP_PLUGIN(YouTubeCapacitorPlugin, "YouTubeCapacitorPlugin",
           CAP_PLUGIN_METHOD(load, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(play, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(pause, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(toggle, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setLockScreenMode, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(stop, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(seekTo, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setVolume, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setNowPlaying, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setUpNext, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setTheme, CAPPluginReturnPromise);
)
