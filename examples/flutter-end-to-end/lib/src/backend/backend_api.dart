import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../session_store.dart';
import 'interceptors.dart';

/// A signed-in user, as the backend describes them.
class AppUser {
  const AppUser({required this.id, required this.email});

  factory AppUser.fromJson(Map<String, dynamic> json) =>
      AppUser(id: json['id'] as String, email: json['email'] as String);

  /// The backend's own user ID: the app sends exactly this string to Clikgate as the customer ID.
  final String id;
  final String email;
}

/// The answer of sign-up, sign-in and `/me`.
class SignedIn {
  const SignedIn({required this.user, this.accessToken, this.identityToken});

  factory SignedIn.fromJson(Map<String, dynamic> json) => SignedIn(
        user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
        accessToken: json['accessToken'] as String?,
        identityToken: json['clikgateIdentityToken'] as String?,
      );

  final AppUser user;

  /// The backend's own session token (null from `/me`, which reuses the saved one).
  final String? accessToken;

  /// Made by the backend with the server SDK; null when the backend uses the installation header instead.
  final String? identityToken;
}

/// Calls one of the sample backends (they all answer the same routes).
class BackendApi {
  BackendApi(this._dio);

  factory BackendApi.create(String baseUrl, SessionStore session, {InstallationHeaderSource? installationHeader}) {
    final dio = Dio(BaseOptions(baseUrl: baseUrl, contentType: Headers.jsonContentType));
    dio.interceptors
      ..add(InstallationHeaderInterceptor(header: installationHeader))
      ..add(AccessTokenInterceptor(session));
    return BackendApi(dio);
  }

  final Dio _dio;

  /// The tests swap its transport for a fake backend.
  @visibleForTesting
  Dio get dio => _dio;

  Future<SignedIn> signUp(String email, String password) =>
      _signedIn(_dio.post('/auth/sign-up', data: {'email': email, 'password': password}));

  Future<SignedIn> signIn(String email, String password) =>
      _signedIn(_dio.post('/auth/sign-in', data: {'email': email, 'password': password}));

  /// "Current user": the app calls it at every open, and gets a fresh identity token each time.
  Future<SignedIn> me() => _signedIn(_dio.get('/me'));

  /// Asks the backend to confirm a payment: it checks with Paystack itself, then tells Clikgate.
  Future<void> confirmPayment(String reference) =>
      _dio.post('/payments/paystack/confirm', data: {'reference': reference});

  Future<SignedIn> _signedIn(Future<Response<dynamic>> request) async {
    final response = await request;
    return SignedIn.fromJson(response.data as Map<String, dynamic>);
  }
}
