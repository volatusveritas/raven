function commands.release()
    raven.run({'odin', 'build', 'raven', '-out:build/raven_release.exe', '-o:speed', '-disable-assert', '-no-bounds-check'})
end

function commands.build()
    raven.run({'odin', 'build', 'raven', '-out:build/raven.exe', '-o:none'})
end

function commands.debug()
    raven.run({'odin', 'build', 'raven', '-out:build/raven_db.exe', '-o:none', '-debug'})
end
