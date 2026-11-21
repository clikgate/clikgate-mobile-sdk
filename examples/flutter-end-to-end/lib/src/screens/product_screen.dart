import 'package:flutter/material.dart';

/// Where a link like `https://inv.myapp.com/product/42` lands.
class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key, required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Product')),
        body: Center(child: Text('Product $productId')),
      );
}
