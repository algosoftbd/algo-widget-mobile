# The SDK reflects on nothing and generates nothing. These rules exist so a
# host app's R8 pass does not strip the entry points it calls by name.
-keep class com.algosoft.widget.AlgoWidget { *; }
-keep class com.algosoft.widget.AlgoWidgetCapture { *; }
