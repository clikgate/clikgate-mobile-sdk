package com.clikgate.sample

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

/** Destination of product deep links (`/products/{id}`). */
class ProductActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Product"
        setContentView(
            TextView(this).apply {
                setPadding(48, 48, 48, 48)
                textSize = 18f
                text = "Product screen\n\npath: ${intent.getStringExtra(EXTRA_PATH)}\ndata: ${intent.getStringExtra(EXTRA_DATA)}"
            },
        )
    }

    companion object {
        const val EXTRA_PATH = "path"
        const val EXTRA_DATA = "data"
    }
}
