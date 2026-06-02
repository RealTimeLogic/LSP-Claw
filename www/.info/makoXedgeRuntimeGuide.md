Mako Server supports .preload and .lsp execution. It can store .xlua files in the lab, but it does not auto-execute them.

Xedge supports .preload, .lsp, and .xlua auto execution. When both mako and xedge globals exist, Mako Server is powering Xedge. When only xedge exists, Xedge is running standalone, typically on a monolithic RTOS powered device.

Use getRuntimeInfo and getLabStatus before copying or activating files. .xlua activation is available only under Xedge and only when the lab is running.
