/**
 * Argument / result type of the TurboModule specs (NativeClikgate, engage/NativeClikgateEngage).
 *
 * @react-native/codegen matches spec types by name: a bare `UnsafeObject` (or `Object`) is a
 * generic object (`ReadableMap` / `NSDictionary`) in every codegen from 0.76 on. The qualified
 * `CodegenTypes.UnsafeObject` is only understood from 0.80, and React Native 0.76–0.79 also have no
 * TypeScript declaration to import `UnsafeObject` from, so the specs import it from here. It must
 * stay in its own file: codegen resolves aliases declared inside a spec file instead of
 * matching them by name.
 */
export type UnsafeObject = object;
