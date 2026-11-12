package com.ayma.ayma_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AssistTextFlattenerTest {

    private fun node(
        text: String? = null,
        desc: String? = null,
        children: List<AssistNodeData> = emptyList(),
    ) = AssistNodeData(text = text, contentDescription = desc, children = children)

    @Test
    fun flattenIsDepthFirstInOrder() {
        val root = node(
            children = listOf(
                node(text = "Title"),
                node(children = listOf(node(text = "Body"), node(text = "Footer"))),
            ),
        )
        assertEquals(listOf("Title", "Body", "Footer"), AssistTextFlattener.flatten(root))
    }

    @Test
    fun contentDescriptionIsTheFallback() {
        val root = node(children = listOf(node(desc = "Search button")))
        assertEquals(listOf("Search button"), AssistTextFlattener.flatten(root))
    }

    @Test
    fun blanksAndDuplicatesAreDropped() {
        val root = node(
            children = listOf(
                node(text = "  "),
                node(text = "Same"),
                node(text = " same "),
                node(text = "SAME"),
                node(text = "Other"),
            ),
        )
        assertEquals(listOf("Same", "Other"), AssistTextFlattener.flatten(root))
    }

    @Test
    fun whitespaceIsCollapsedAndLongTextCapped() {
        val long = "word ".repeat(200)
        val root = node(children = listOf(node(text = "a  b\tc"), node(text = long)))
        val out = AssistTextFlattener.flatten(root)
        assertEquals("a b c", out[0])
        assertEquals(AssistTextFlattener.MAX_TEXT_CHARS, out[1].length)
    }

    @Test
    fun nodeCapStopsTraversal() {
        val kids = (1..(AssistTextFlattener.MAX_TEXTS + 50)).map { node(text = "t$it") }
        val out = AssistTextFlattener.flatten(node(children = kids))
        assertEquals(AssistTextFlattener.MAX_TEXTS, out.size)
    }

    @Test
    fun nullRootFlattensToEmpty() {
        assertTrue(AssistTextFlattener.flatten(null).isEmpty())
    }

    @Test
    fun joinCappedRespectsTheCap() {
        val joined = AssistTextFlattener.joinCapped(listOf("aaaa", "bbbb", "cccc"), 9)
        assertTrue(joined.length <= 9)
        assertEquals("aaaa\nbbbb", joined)
    }
}
