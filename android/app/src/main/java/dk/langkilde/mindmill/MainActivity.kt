package dk.langkilde.mindmill

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import dk.langkilde.mindmill.ui.MindmillRoot
import dk.langkilde.mindmill.ui.MindmillTheme
import dk.langkilde.mindmill.ui.ProvideApp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as MindmillApp
        setContent {
            ProvideApp(app) {
                MindmillTheme {
                    Surface(Modifier.fillMaxSize()) { MindmillRoot() }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        (application as MindmillApp).connection.onForeground()
    }
}
