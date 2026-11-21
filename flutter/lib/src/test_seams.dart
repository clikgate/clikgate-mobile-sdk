import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Internal: the HTTP client a `ClikgateEngage` created without its own `httpClient` uses, when set.
/// Only `package:clikgate_flutter/testing.dart` sets it; apps never do. Not exported.
@internal
http.Client Function()? engageHttpClientOverride;
