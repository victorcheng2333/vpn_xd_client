package com.xd.vpn.android

import android.app.Application
import com.xd.vpn.android.data.VPNRepository
class VPNApplication : Application() {
    val repository by lazy { VPNRepository(this) }
}
