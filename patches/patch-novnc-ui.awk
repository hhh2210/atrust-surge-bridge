{
    print
    if ($0 == "        UI.initSettings();") {
        print ""
        print "        // The password arrived in the URL fragment, so the HTTP server never saw it."
        print "        // noVNC has cached it by this point; remove it from the visible URL/history."
        print "        const fragment = new URLSearchParams(window.location.hash.slice(1));"
        print "        if (fragment.has('password')) {"
        print "            fragment.delete('password');"
        print "            const suffix = fragment.toString();"
        print "            window.history.replaceState(null, document.title,"
        print "                window.location.pathname + window.location.search +"
        print "                (suffix ? '#' + suffix : ''));"
        print "        }"
        patched++
    }
}

END {
    if (patched != 1) exit 42
}
