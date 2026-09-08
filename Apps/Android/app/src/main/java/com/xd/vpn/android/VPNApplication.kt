package com.xd.vpn.android

import android.app.Application
import com.xd.vpn.android.data.VPNRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class VPNApplication : Application() {
    val repository by lazy { VPNRepository(this) }
    /** Configuration writes outlive the Activity: a rotation must neither cancel a save nor report it as failed. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
}
