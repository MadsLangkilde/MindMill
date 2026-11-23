package dk.langkilde.mindmill.store

import dk.langkilde.mindmill.remote.bool
import dk.langkilde.mindmill.remote.int
import dk.langkilde.mindmill.remote.jsonOf
import dk.langkilde.mindmill.remote.parseJsonObject
import dk.langkilde.mindmill.remote.string
import dk.langkilde.mindmill.remote.strings
import kotlinx.serialization.json.JsonObject

/** The Mac this phone is paired with. The device token is the only secret, and it only opens this one Mac. */
data class StoredPairing(
    val macName: String,
    val hosts: List<String>,
    val port: Int,
    val fingerprint: String,
    val token: String,
    val lastHost: String? = null,
) {
    fun toJson(): JsonObject = jsonOf(
        FIELD_NAME to macName, FIELD_HOSTS to hosts, FIELD_PORT to port,
        FIELD_FINGERPRINT to fingerprint, FIELD_TOKEN to token, FIELD_LAST_HOST to lastHost,
    )

    /** Hosts to try, the one that answered last time first. */
    val orderedHosts: List<String> get() = listOfNotNull(lastHost).plus(hosts).distinct()

    companion object {
        const val FIELD_NAME = "name"
        const val FIELD_HOSTS = "hosts"
        const val FIELD_PORT = "port"
        const val FIELD_FINGERPRINT = "fingerprint"
        const val FIELD_TOKEN = "token"
        const val FIELD_LAST_HOST = "lastHost"
        val FIELDS = setOf(FIELD_NAME, FIELD_HOSTS, FIELD_PORT, FIELD_FINGERPRINT, FIELD_TOKEN, FIELD_LAST_HOST)

        fun fromJson(o: JsonObject): StoredPairing? {
            val token = o.string(FIELD_TOKEN)?.takeIf { it.isNotEmpty() } ?: return null
            val fp = o.string(FIELD_FINGERPRINT) ?: return null
            val hosts = o.strings(FIELD_HOSTS).takeIf { it.isNotEmpty() } ?: return null
            return StoredPairing(o.string(FIELD_NAME) ?: "Mac", hosts, o.int(FIELD_PORT) ?: 7878, fp, token, o.string(FIELD_LAST_HOST))
        }
    }
}

/** Plain preferences: nothing secret. */
data class AppSettings(
    val scope: String? = null,
    val keylessOnly: Boolean = false,
    val routeToHeadset: Boolean = true,
    val meetingAutoScreens: Boolean = false,
    /** Plan or Build, as last chosen at the top. */
    val mode: String = "plan",
) {
    fun toJson(): JsonObject = jsonOf(
        FIELD_SCOPE to scope, FIELD_KEYLESS_ONLY to keylessOnly,
        FIELD_ROUTE_HEADSET to routeToHeadset, FIELD_MEETING_SCREENS to meetingAutoScreens, FIELD_MODE to mode,
    )

    companion object {
        const val FIELD_SCOPE = "scope"
        const val FIELD_KEYLESS_ONLY = "keylessOnly"
        const val FIELD_ROUTE_HEADSET = "routeToHeadset"
        const val FIELD_MEETING_SCREENS = "meetingAutoScreens"
        const val FIELD_MODE = "mode"
        val FIELDS = setOf(FIELD_SCOPE, FIELD_KEYLESS_ONLY, FIELD_ROUTE_HEADSET, FIELD_MEETING_SCREENS, FIELD_MODE)

        fun fromJson(o: JsonObject?) = AppSettings(
            scope = o.string(FIELD_SCOPE),
            keylessOnly = o.bool(FIELD_KEYLESS_ONLY) ?: false,
            routeToHeadset = o.bool(FIELD_ROUTE_HEADSET) ?: true,
            meetingAutoScreens = o.bool(FIELD_MEETING_SCREENS) ?: false,
            mode = o.string(FIELD_MODE) ?: "plan",
        )
    }
}

interface KeyValueStore {
    fun get(name: String): String?
    fun put(name: String, value: String?)
    fun names(): Set<String>
}

interface BlobCipher {
    fun encrypt(plain: ByteArray): String
    fun decrypt(sealed: String): ByteArray?
}

/** Everything the app persists: the pairing (encrypted with a Keystore key) and plain settings. Nothing else. */
class PairingStore(private val kv: KeyValueStore, private val cipher: BlobCipher) {
    fun loadPairing(): StoredPairing? {
        val sealed = kv.get(ENTRY_PAIRING) ?: return null
        val plain = cipher.decrypt(sealed) ?: return null
        return parseJsonObject(String(plain, Charsets.UTF_8))?.let(StoredPairing::fromJson)
    }

    fun savePairing(p: StoredPairing) = kv.put(ENTRY_PAIRING, cipher.encrypt(p.toJson().toString().toByteArray(Charsets.UTF_8)))

    fun clearPairing() = kv.put(ENTRY_PAIRING, null)

    fun loadSettings(): AppSettings = AppSettings.fromJson(kv.get(ENTRY_SETTINGS)?.let(::parseJsonObject))

    fun saveSettings(s: AppSettings) = kv.put(ENTRY_SETTINGS, s.toJson().toString())

    companion object {
        const val ENTRY_PAIRING = "pairing"
        const val ENTRY_SETTINGS = "settings"
        val ENTRIES = setOf(ENTRY_PAIRING, ENTRY_SETTINGS)
    }
}
