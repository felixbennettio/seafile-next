package com.seafile.seadroid2.util;

import static org.junit.Assert.assertEquals;

import com.seafile.seadroid2.ui.comparator.StringNaturalOrderComparator;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

public class NaturalOrderComparatorTest {
    @Test public void accentedNamesStillSortNumbersNaturally() {
        for (String prefix : Arrays.asList("ä", "é", "文件")) {
            List<String> names = new ArrayList<>(Arrays.asList(prefix + "10", prefix + "2", prefix + "1"));
            Collections.sort(names, new StringNaturalOrderComparator());
            assertEquals(Arrays.asList(prefix + "1", prefix + "2", prefix + "10"), names);
        }
    }

    @Test public void numbersBeyondLongRangeSortInBothDirections() {
        List<String> names = new ArrayList<>(Arrays.asList(
                "file100000000000000000000", "file10", "file2", "file99999999999999999999"));
        Collections.sort(names, new StringNaturalOrderComparator());
        assertEquals(Arrays.asList("file2", "file10", "file99999999999999999999", "file100000000000000000000"), names);
        Collections.sort(names, new StringNaturalOrderComparator().reversed());
        assertEquals(Arrays.asList("file100000000000000000000", "file99999999999999999999", "file10", "file2"), names);
    }

    @Test public void missingNamesDoNotCrashAndLeadingZerosSortAfterTheShorterName() {
        List<String> names = new ArrayList<>(Arrays.asList("file02", "file2", null, ""));
        Collections.sort(names, new StringNaturalOrderComparator());
        assertEquals(Arrays.asList(null, "", "file2", "file02"), names);
    }
}
