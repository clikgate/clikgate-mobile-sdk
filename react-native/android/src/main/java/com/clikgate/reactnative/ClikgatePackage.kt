package com.clikgate.reactnative

import com.clikgate.reactnative.engage.ClikgateEngageModule
import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/** Autolinked package registering the `Clikgate` and (Engage share menu) `ClikgateEngage` TurboModules. */
class ClikgatePackage : BaseReactPackage() {
  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
    when (name) {
      ClikgateModule.NAME -> ClikgateModule(reactContext)
      ClikgateEngageModule.NAME -> ClikgateEngageModule(reactContext)
      else -> null
    }

  // Positional arguments: React Native 0.76 names the constructor parameters `_name`,
  // `_className`, ... and later versions `name`, `className`, ...
  override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
    mapOf(
      ClikgateModule.NAME to ReactModuleInfo(
        /* name */ ClikgateModule.NAME,
        /* className */ ClikgateModule::class.java.name,
        /* canOverrideExistingModule */ false,
        // Created at startup so the launch intent and the native deep-link listener are
        // installed before JS runs (the SDK buffers until configure is called from JS).
        /* needsEagerInit */ true,
        /* isCxxModule */ false,
        /* isTurboModule */ true,
      ),
      ClikgateEngageModule.NAME to ReactModuleInfo(
        /* name */ ClikgateEngageModule.NAME,
        /* className */ ClikgateEngageModule::class.java.name,
        /* canOverrideExistingModule */ false,
        /* needsEagerInit */ false,
        /* isCxxModule */ false,
        /* isTurboModule */ true,
      ),
    )
  }
}
