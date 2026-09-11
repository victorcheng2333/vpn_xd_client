package com.xd.vpn.android

import com.xd.vpn.android.core.StatsDemand
import com.xd.vpn.android.core.StatsPoller
import org.junit.Assert.*
import org.junit.Test

class StatsPollingTest {
    private class Queue {
        data class Item(val task: Runnable, val at: Long)
        var now = 0L
        val items = mutableListOf<Item>()
        fun post(task: Runnable, delay: Long) { items.add(Item(task, now + delay)) }
        fun remove(task: Runnable) { items.removeAll { it.task === task } }
        fun advance(milliseconds: Long) {
            val end = now + milliseconds
            while (true) {
                val next = items.minByOrNull { it.at }?.takeIf { it.at <= end } ?: break
                items.remove(next); now = next.at; next.task.run()
            }
            now = end
        }
    }

    @Test fun overlappingObserversAndRepeatedDisposalDoNotLoseDemand() {
        val demand = StatsDemand()
        assertFalse(demand.active.value)
        val oldActivity = demand.acquire()
        val newActivity = demand.acquire()
        assertTrue(demand.active.value)
        oldActivity.close(); oldActivity.close()
        assertTrue(demand.active.value)
        newActivity.close()
        assertFalse(demand.active.value)
        val reopened = demand.acquire()
        assertTrue(demand.active.value)
        reopened.close()
        assertFalse(demand.active.value)
    }

    @Test fun noObservationOrNoConnectedEngineLeavesNoTimer() {
        val queue = Queue()
        var requests = 0
        val poller = StatsPoller<Any>(queue::post, queue::remove) { requests++ }
        poller.update(false, Any())
        poller.update(true, null) // Service absent, startup, offline wait or recovery cooldown.
        queue.advance(3_600_000)
        assertEquals(0, requests); assertTrue(queue.items.isEmpty())
    }

    @Test fun becomingVisibleSamplesImmediatelyAndRepeatedUpdatesHaveOneSchedule() {
        val queue = Queue()
        val engine = Any()
        val sampled = mutableListOf<Any>()
        val poller = StatsPoller(queue::post, queue::remove, sampled::add)
        repeat(10) { poller.update(true, engine) }
        assertEquals(1, queue.items.size)
        queue.advance(0)
        assertEquals(listOf(engine), sampled)
        repeat(10) { poller.update(true, engine) }
        queue.advance(4_999); assertEquals(1, sampled.size)
        queue.advance(1); assertEquals(2, sampled.size)
        assertEquals(1, queue.items.size)
    }

    @Test fun backgroundCancelsAlreadyDequeuedCallbackAndForegroundGetsFreshSample() {
        val queue = Queue()
        val engine = Any()
        var requests = 0
        val poller = StatsPoller<Any>(queue::post, queue::remove) { requests++ }
        poller.update(true, engine); queue.advance(0)
        val stale = queue.items.single().task
        poller.update(false, engine)
        stale.run(); queue.advance(3_600_000)
        assertEquals(1, requests); assertTrue(queue.items.isEmpty())
        poller.update(true, engine); queue.advance(0)
        assertEquals(2, requests); assertEquals(1, queue.items.size)
    }

    @Test fun replacingAnEngineCannotSampleOrRescheduleTheOldEngine() {
        val queue = Queue()
        val oldEngine = Any(); val newEngine = Any()
        val sampled = mutableListOf<Any>()
        val poller = StatsPoller(queue::post, queue::remove, sampled::add)
        poller.update(true, oldEngine); queue.advance(0)
        val stale = queue.items.single().task
        poller.update(true, newEngine)
        stale.run(); queue.advance(0)
        assertEquals(listOf(oldEngine, newEngine), sampled)
        queue.advance(5_000)
        assertEquals(listOf(oldEngine, newEngine, newEngine), sampled)
        assertEquals(1, queue.items.size)
    }

    @Test fun failedEngineStopsPollingAndRecoveryDoesNotWaitForTheOldTick() {
        val queue = Queue()
        var requests = 0
        val poller = StatsPoller<Any>(queue::post, queue::remove) { requests++ }
        poller.update(true, Any()); queue.advance(0)
        poller.update(true, null)
        queue.advance(60_000)
        assertEquals(1, requests); assertTrue(queue.items.isEmpty())
        poller.update(true, Any()); queue.advance(0)
        assertEquals(2, requests)
    }

    @Test fun destroyedServiceCannotBeReactivatedByQueuedObservationOrEngineCallbacks() {
        val queue = Queue()
        var requests = 0
        val poller = StatsPoller<Any>(queue::post, queue::remove) { requests++ }
        poller.update(true, Any())
        val stale = queue.items.single().task
        poller.close(); poller.close()
        poller.update(true, Any()); stale.run(); queue.advance(60_000)
        assertEquals(0, requests); assertTrue(queue.items.isEmpty())
        val replacement = StatsPoller<Any>(queue::post, queue::remove) { requests++ }
        replacement.update(true, Any()); queue.advance(0)
        assertEquals(1, requests)
    }

    @Test fun requestThatSynchronouslyStopsObservationCannotRequeueItself() {
        val queue = Queue()
        var requests = 0
        lateinit var poller: StatsPoller<Any>
        poller = StatsPoller(queue::post, queue::remove) { requests++; poller.update(false, null) }
        poller.update(true, Any()); queue.advance(60_000)
        assertEquals(1, requests); assertTrue(queue.items.isEmpty())
    }
}
