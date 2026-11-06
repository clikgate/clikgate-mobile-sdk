package com.clikgate.reactnative

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/** Autolinked package registering the `Clikgate` TurboModule. */
class ClikgatePackage : BaseReactPackage() {
  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
    if (name == ClikgateModule.NAME) ClikgateModule(reactContext) else null

  override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
    mapOf(
      ClikgateModule.NAME to ReactModuleInfo(
        name = ClikgateModule.NAME,
        className = ClikgateModule::class.java.name,
        canOverrideExistingModule = false,
        // Created at startup so the launch intent and the native deep-link listener are
        // installed before JS runs (the SDK buffers until configure is called from JS).
        needsEagerInit = true,
        isCxxModule = false,
        isTurboModule = true,
      ),
    )
  }
}
