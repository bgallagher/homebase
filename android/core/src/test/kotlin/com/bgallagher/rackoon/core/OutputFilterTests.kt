package com.bgallagher.rackoon.core

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private fun spans(s: String): List<Pair<String, HighlightKind>> {
    val bytes = s.toByteArray()
    return OutputHighlighter.spans(s).map { String(bytes, it.start, it.end - it.start) to it.kind }
}

class OutputHighlighterTests {
    @Test fun ipv4() {
        val r = spans("IPv4 address for eth0: 89.167.95.123 and https://10.0.0.1:9090/ ok")
        assertEquals(listOf("89.167.95.123", "10.0.0.1"), r.map { it.first })
        assertTrue(r.all { it.second == HighlightKind.IP_ADDRESS })
    }

    @Test fun ipv4Rejections() {
        assertTrue(spans("version 1.2.3 and 256.1.1.1 and 1.2.3.4.5 and 300.300.300.300").isEmpty(), "out-of-range octets and 5-part dotted numbers are not IPs")
        assertTrue(spans("abc1.2.3.4").isEmpty(), "must not start inside a word")
    }

    @Test fun ipv6() {
        assertEquals(listOf("2a01:4f9:c014:2ddc::1"), spans("IPv6 address for eth0: 2a01:4f9:c014:2ddc::1").map { it.first })
        assertEquals(listOf("fe80::1"), spans("link fe80::1 up").map { it.first })
        assertEquals(listOf("2001:0db8:0000:0000:0000:ff00:0042:8329"), spans("2001:0db8:0000:0000:0000:ff00:0042:8329").map { it.first })
    }

    @Test fun ipv6LookalikesAreIgnored() {
        assertTrue(spans("at 11:26:02 PM").isEmpty(), "a time")
        assertTrue(spans("mac aa:bb:cc:dd:ee:ff end").isEmpty(), "a MAC address")
        assertTrue(spans("ratio 3:1").isEmpty())
    }

    @Test fun words() {
        assertEquals(listOf(HighlightKind.ERROR, HighlightKind.ERROR), spans("Build FAILED: permission denied").map { it.second })
        assertEquals(listOf(HighlightKind.WARNING), spans("warning: deprecated").map { it.second })
        assertEquals(listOf(HighlightKind.SUCCESS, HighlightKind.SUCCESS), spans("Tests passed. Successfully installed").map { it.second })
        assertTrue(spans("errors: 0, terror, warned").isEmpty(), "whole words only; plurals and substrings are not matched")
    }

    @Test fun percentThresholds() {
        assertEquals(listOf("91%|ERROR"), spans("Usage of /: 91% of 37G").map { "${it.first}|${it.second}" })
        assertEquals(listOf("80%|WARNING"), spans("disk 80%").map { "${it.first}|${it.second}" })
        assertTrue(spans("cpu 43.1% of 37.23GB").isEmpty())
        assertEquals(listOf("99.5%"), spans("use 99.5%").map { it.first })
    }

    @Test fun offsetsAreUTF8BytesEvenWithMultibyteText() {
        val s = "héllo 日本 10.0.0.1"
        val sp = OutputHighlighter.spans(s)
        assertEquals(1, sp.size)
        assertEquals("10.0.0.1", String(s.toByteArray(), sp[0].start, sp[0].end - sp[0].start))
    }

    @Test fun overlapsKeepTheEarlierSpan() {
        val r = OutputHighlighter.resolve(
            listOf(HighlightSpan(0, 5, HighlightKind.ERROR), HighlightSpan(3, 8, HighlightKind.WARNING), HighlightSpan(8, 9, HighlightKind.SUCCESS)),
        )
        assertEquals(listOf(HighlightKind.ERROR, HighlightKind.SUCCESS), r.map { it.kind })
    }
}

class TerminalOutputFilterTests {
    private val esc = "\u001B"
    private fun run(f: TerminalOutputFilter, s: String) = String(f.process(s.toByteArray()))

    /** Removes exactly the colour pairs the filter inserts, to prove it never changes anything else. */
    private fun stripInjected(s: String): String {
        var t = s
        for (c in listOf("31", "32", "33", "35")) t = t.replace("\u001B[${c}m", "")
        return t.replace("\u001B[39m", "")
    }

    @Test fun coloursAnIPInPlainOutput() {
        val out = run(TerminalOutputFilter(), "IPv4 address for eth0: 89.167.95.123\r\nnext line\r\n")
        assertEquals("IPv4 address for eth0: $esc[35m89.167.95.123$esc[39m\r\nnext line\r\n", out)
    }

    @Test fun disabledIsAnExactPassThrough() {
        val f = TerminalOutputFilter().apply { isEnabled = false }
        val s = "error at 10.0.0.1 $esc[1;31mred$esc[0m\r\n"
        assertContentEquals(s.toByteArray(), f.process(s.toByteArray()))
    }

    @Test fun leavesProgramColouredTextAlone() {
        val out = run(TerminalOutputFilter(), "$esc[32mserver 10.0.0.1$esc[0m and 10.0.0.2\r\n")
        assertFalse(out.contains("$esc[35m10.0.0.1"), "inside the program's own green")
        assertTrue(out.contains("$esc[35m10.0.0.2$esc[39m"), "after reset, highlighting resumes")
    }

    @Test fun backgroundAnd256ColourAndReverseAlsoSuppress() {
        for (set in listOf("$esc[44m", "$esc[38;5;196m", "$esc[38;2;1;2;3m", "$esc[7m", "$esc[1;33;40m")) {
            assertEquals("${set}10.0.0.1 \r\n", run(TerminalOutputFilter(), "${set}10.0.0.1 \r\n"), set)
        }
        val f = TerminalOutputFilter()
        run(f, "$esc[7m")
        assertEquals("$esc[27m$esc[35m10.0.0.1$esc[39m x", run(f, "$esc[27m10.0.0.1 x"), "27 clears reverse")
    }

    @Test fun subparameterFormsDoNotBreakTracking() {
        // 38;5;n consumes its own parameters, so the trailing 0 is a real reset.
        assertTrue(run(TerminalOutputFilter(), "$esc[38;5;196;0m10.0.0.1 x").contains("$esc[35m10.0.0.1"), "reset after a 256-colour parameter is honoured")
    }

    @Test fun alternateScreenIsNeverTouched() {
        val out = run(TerminalOutputFilter(), "$esc[?1049h10.0.0.1 error $esc[?1049l and 10.0.0.2 x")
        assertTrue(out.contains("$esc[?1049h10.0.0.1 error $esc[?1049l"))
        assertTrue(out.contains("$esc[35m10.0.0.2$esc[39m"))
    }

    @Test fun escapeSequencesPassThroughUnchanged() {
        // Window title containing an IP, a charset select, cursor movement, and a DCS string.
        val s = "$esc]0;root@10.0.0.1: ~\u0007$esc(B$esc[2;5H$esc[K${esc}Pq10.0.0.2$esc\\hello\r\n"
        assertEquals(s, run(TerminalOutputFilter(), s))
    }

    @Test fun chunkEdgeMatchesAreSkippedNotMangled() {
        val f = TerminalOutputFilter()
        val a = run(f, "ip 10.0.0.1") // ends exactly at the token: might continue
        val b = run(f, "23 done\r\n") // continues it
        assertEquals("ip 10.0.0.123 done\r\n", a + b, "no colour is better than a wrong colour")
    }

    @Test fun typedEchoByteByByteIsUnchanged() {
        val f = TerminalOutputFilter()
        var all = ""
        for (ch in "ping 10.0.0.1\r\n") all += run(f, ch.toString())
        assertEquals("ping 10.0.0.1\r\n", all)
    }

    @Test fun multibyteCharactersSplitAcrossChunks() {
        val f = TerminalOutputFilter()
        var out = ByteArray(0)
        for (b in "café 日本 10.0.0.1 x\r\n".toByteArray()) out += f.process(byteArrayOf(b))
        out += f.process(ByteArray(0))
        assertEquals("café 日本 10.0.0.1 x\r\n", stripInjected(String(out)))
    }

    /** Whatever the chunking, the filter must only ever add colour pairs. */
    @Test fun randomChunkingNeverCorruptsOutput() {
        val corpus = "System load: 0.44  Usage of /: 91% of 37G\r\nIPv4 address for eth0: 89.167.95.123\r\n" +
            "$esc[1;32mok$esc[0m build FAILED at 10.0.0.9\r\nIPv6: 2a01:4f9:c014:2ddc::1 warning: x\r\n" +
            "$esc]0;title 10.0.0.1\u0007$esc[?1049hfull screen 1.2.3.4$esc[?1049l tail 8.8.8.8 \r\n"
        val bytes = corpus.toByteArray()
        val rng = Random(42)
        repeat(300) {
            val f = TerminalOutputFilter()
            var out = ByteArray(0)
            var i = 0
            while (i < bytes.size) {
                val n = rng.nextInt(1, 10)
                out += f.process(bytes.copyOfRange(i, minOf(i + n, bytes.size)))
                i += n
            }
            out += f.process(ByteArray(0))
            assertEquals(corpus, stripInjected(String(out)))
        }
    }

    @Test fun stateIsTrackedWhileDisabledSoEnablingMidStreamIsCorrect() {
        val f = TerminalOutputFilter().apply { isEnabled = false }
        assertEquals("$esc[?1049h", run(f, "$esc[?1049h"), "disabled output is untouched") // vim starts while highlighting is off
        f.isEnabled = true
        assertEquals("inside vim 10.0.0.1 x", run(f, "inside vim 10.0.0.1 x"), "still on the alternate screen: no colour")
        assertTrue(run(f, "$esc[?1049l back 10.0.0.2 x").contains("$esc[35m10.0.0.2"), "colour returns after vim exits")

        val g = TerminalOutputFilter().apply { isEnabled = false }
        run(g, "$esc[32m") // a program sets green while we are off
        g.isEnabled = true
        assertEquals("10.0.0.1 x", run(g, "10.0.0.1 x"), "the program's own colour is still respected")
    }

    /** The strongest "off" guarantee: for ANY bytes, a disabled filter returns exactly what it was given. */
    @Test fun disabledFilterIsAnExactIdentityForArbitraryBytes() {
        val rng = Random(7)
        val f = TerminalOutputFilter().apply { isEnabled = false }
        val specials = "\u001B[0m\u001B]0;t\u0007\u001B[?1049h 10.0.0.1 error 99%\r\n".toByteArray()
        repeat(3000) {
            val n = rng.nextInt(0, 81)
            val chunk = ByteArray(n) { if (rng.nextBoolean()) specials[rng.nextInt(specials.size)] else rng.nextInt(0, 256).toByte() }
            assertContentEquals(chunk, f.process(chunk))
        }
    }

    @Test fun fastPathDoesNotLoseStateAcrossAnEscapeLater() {
        val f = TerminalOutputFilter().apply { isEnabled = false }
        assertEquals("plain text with no escapes at all\r\n", run(f, "plain text with no escapes at all\r\n"))
        run(f, "$esc[?1049h") // slow path: tracks the alternate screen
        assertEquals("10.0.0.1 more plain bytes", run(f, "10.0.0.1 more plain bytes")) // fast path again
        f.isEnabled = true
        assertEquals("10.0.0.1 x", run(f, "10.0.0.1 x"), "the alternate screen was remembered through the fast path")
    }

    @Test fun disabledFilterHoldsNothingBack() {
        val f = TerminalOutputFilter().apply { isEnabled = false }
        val euro = byteArrayOf(0xE2.toByte(), 0x82.toByte(), 0xAC.toByte())
        assertContentEquals(euro.copyOfRange(0, 2), f.process(euro.copyOfRange(0, 2)), "no buffering when off")
        assertContentEquals(ByteArray(0), f.finish())
    }

    @Test fun finishReleasesAHeldBackPartialCharacter() {
        val f = TerminalOutputFilter()
        val euro = byteArrayOf(0xE2.toByte(), 0x82.toByte(), 0xAC.toByte())
        assertContentEquals(ByteArray(0), f.process(euro.copyOfRange(0, 2)), "incomplete character is held back")
        assertContentEquals(euro.copyOfRange(0, 2), f.finish(), "and released unmodified when the stream ends")
        assertContentEquals(ByteArray(0), f.finish())
    }

    @Test fun garbageInputNeverCrashes() {
        val rng = Random(1)
        val f = TerminalOutputFilter()
        repeat(2000) { f.process(ByteArray(rng.nextInt(0, 65)) { rng.nextInt(0, 256).toByte() }) }
    }
}
