/** **************************************************************************
 * HaxeServer.hx
 *
 * Copyright (c) 2013 by the contributors
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following condition is met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *
 * THIS SOFTWARE IS PROVIDED BY THE HAXE PROJECT CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED.
 ************************************************************************** **/

package debugger;

import debugger.HaxeProtocol;
import debugger.IController;

#if cpp
import cpp.vm.Deque;
import cpp.vm.Thread;
#elseif neko
import neko.vm.Deque;
import neko.vm.Thread;
#else
#error "AdvancedDebuggerServer supported only for cpp and neko targets"
#end

/**
 * This is a standalone program which acts as a debug server speaking with
 * clients using Haxe serialization format.  To use, start it up (giving an
 * optional port number to listen on as the only possible argument).  Then run
 * a debugging client to connect to it.  Now your debug server will send
 * commands to and read messages from the remotely being debugged client.
 **/
class HaxeServer
{
    public static function main()
    {
        var port : Int = 6972;

        var args = Sys.args();
        if (args.length > 0) {
            port = Std.parseInt(args[0]);
        }

        new HaxeServer(new CommandLineController(), port);
    }

    /**
     * Creates a server.  This function never returns.
     **/
    public function new(controller : CommandLineController,
                        port : Int = 6972)
                        
    {
        mController = controller;
        mSocketQueue = new Deque<sys.net.Socket>();
        mCommandQueue = new Deque<Command>();
        mReadCommandQueue = new Deque<Bool>();
        Thread.create(readCommandMain);

        var listenSocket : sys.net.Socket = null;

        while (listenSocket == null) {
            listenSocket = new sys.net.Socket();
            try {
                listenSocket.bind
                    (new sys.net.Host(sys.net.Host.localhost()), port);
                listenSocket.listen(1);
            }
            catch (e : Dynamic) {
                Sys.println("Failed to bind/listen on port " + 
                            port + ": " + e);
                Sys.println("Trying again in 3 seconds.");
                Sys.sleep(3);
                listenSocket.close();
                listenSocket = null;
            }
        }

        while (true) {

            var socket : sys.net.Socket = null;

            while (socket == null) {
                try {
                    Sys.println("\nListening for client connection ...");
                    socket = listenSocket.accept();
                }
                catch (e : Dynamic) {
                    Sys.println("Failed to accept connection on port " + 
                                port + ": " + e);
                    Sys.println("Trying again in 1 second.");
                    Sys.sleep(1);
                }
            }

            var peer = socket.peer();
            Sys.println("\nReceived connection from " + peer.host + ".");

            HaxeProtocol.writeServerIdentification(socket.output);
            HaxeProtocol.readClientIdentification(socket.input);

            // Push the socket to the command thread to read from
            mSocketQueue.push(socket);
            mReadCommandQueue.push(true);

            try {
                while (true) {
                    // Read messages from server and pass them on to the
                    // controller.  But first check the type; only allow
                    // the next prompt to be printed on non-thread messages.
                    var message : Message =
                        HaxeProtocol.readMessage(socket.input);

                    var okToShowPrompt : Bool = false;

                    switch (message) {
                    case ThreadCreated(number):
                    case ThreadTerminated(number):
                    case ThreadStarted(number):
                    case ThreadStopped(number, className, functionName,
                                       fileName, lineNumber):
                    default:
                        okToShowPrompt = true;
                    }

                    controller.acceptMessage(message);

                    if (okToShowPrompt) {
                        // OK to show the next prompt; pop whatever is there
                        // to ensure that there is never more than one element
                        // in there.  This helps with "source" commands that
                        // issue tons of commands in sequence
                        while (mReadCommandQueue.pop(false)) {
                        }
                        mReadCommandQueue.push(true);
                    }
                }
            }
            catch (e : haxe.io.Eof) {
                Sys.println("Client disconnected.\n");
            }
            catch (e : Dynamic) {
                Sys.println("Error while reading message from client: " + e);
            }
            socket.close();
        }
    }

    public function readCommandMain()
    {
        while (true) {
            // Get the next socket to use
            var socket = mSocketQueue.pop(true);

            // Read commands from the controller and pass them on to the
            // server
            try {
                while (true) {
                    // Wait until the command prompt should be shown
                    mReadCommandQueue.pop(true);

                    HaxeProtocol.writeCommand
                        (socket.output, mController.getNextCommand());
                }
            }
            catch (e : haxe.io.Eof) {
            }
            catch (e : Dynamic) {
                Sys.println("Error while writing command to client: " + e);
                socket.close();
            }
        }
    }

    private var mController : CommandLineController;
    private var mSocketQueue : Deque<sys.net.Socket>;
    private var mCommandQueue : Deque<Command>;
    private var mReadCommandQueue : Deque<Bool>;
}
