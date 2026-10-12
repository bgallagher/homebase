package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FaviconLinksTests {
    private val base = "https://app.example.com/dash/index.html"

    @Test fun originIsTheCacheKey() {
        assertEquals("https://app.example.com", FaviconLinks.origin("https://App.Example.com/x?y=1"))
        assertEquals("https://a.com", FaviconLinks.origin("https://a.com:443/"))
        assertEquals("http://100.125.183.84:8080", FaviconLinks.origin("http://100.125.183.84:8080/path"))
        assertEquals("http://a.com", FaviconLinks.origin("http://a.com:80"))
        assertNull(FaviconLinks.origin("ftp://a.com"))
        assertNull(FaviconLinks.origin("not a url"))
        assertEquals("http://a.com:8080/favicon.ico", FaviconLinks.defaultIcon("http://a.com:8080"))
    }

    @Test fun ranksAppleTouchThenPngThenSvgThenIcoAndResolvesRelativeLinks() {
        val html = """
        <html><head>
        <link rel="stylesheet" href="/s.css">
        <link rel="shortcut icon" href="/favicon.ico">
        <link rel="icon" type="image/svg+xml" href="logo.svg">
        <LINK REL="icon" TYPE="image/png" sizes="32x32" HREF='/img/32.png'>
        <link rel="icon" type="image/png" sizes="16x16 48x48" href="/img/48.png">
        <link rel="apple-touch-icon" sizes="180x180" href="//cdn.example.com/touch.png">
        <link rel="mask-icon" href="/mask.svg" color="#000">
        </head></html>
        """
        assertEquals(
            listOf("https://cdn.example.com/touch.png", "https://app.example.com/img/48.png", "https://app.example.com/img/32.png",
                "https://app.example.com/dash/logo.svg", "https://app.example.com/favicon.ico"),
            FaviconLinks.candidates(html, base).map { it.url },
        )
    }

    @Test fun skipsNonHttpAndNonIconLinksAndDuplicates() {
        val html = """
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="javascript:alert(1)">
        <link rel="canonical" href="https://app.example.com/">
        <link rel="icon" href="/a.png"><link rel="icon" href="/a.png">
        <link rel="icon">
        """
        assertEquals(listOf("https://app.example.com/a.png"), FaviconLinks.candidates(html, base).map { it.url })
        assertTrue(FaviconLinks.candidates("<html>no links</html>", base).isEmpty())
    }

    @Test fun attributeParsingHandlesQuotesEntitiesAndOrder() {
        val attrs = FaviconLinks.attributes("""<link href="/i.png?a=1&amp;b=2" rel=icon type='image/png' sizes=64x64>""")
        assertEquals("/i.png?a=1&b=2", attrs["href"])
        assertEquals("icon", attrs["rel"])
        assertEquals("image/png", attrs["type"])
        assertEquals("64x64", attrs["sizes"])
    }

    @Test fun limit() {
        val html = (1..9).joinToString("") { """<link rel="icon" sizes="${it}x$it" href="/$it.png">""" }
        assertEquals(3, FaviconLinks.candidates(html, base, limit = 3).size)
        assertEquals(9, FaviconLinks.candidates(html, base, limit = 3).first().size)
    }
}
