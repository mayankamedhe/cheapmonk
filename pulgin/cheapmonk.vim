" Source Code for our plugin. Be sure to check out the user
" manual by typing :help cheapmonk.

" To open folds, go over each fold and press type za
set foldlevelstart=0

" This global variable stores the name of the buffer
" in which StartReading() method is called.
let g:currentBufName = ""

" Stores the name of the buffer which is to be updated
" by the content recieved from the client.
let g:thisBufname = ""

" Stores the content recieved from the client.
let g:newText = ""

" Stores the timer IDs of the different timers. One 
" timer object is used for each connected client. More
" on this later
let g:timer_dictionary = {}

" StartWriting(ip,name,pwd,delay)------------------------------------------------{{{
" We have kept 8765 as the port number for the server. When a client calls
" this method, a channel (Read Socket) is opened and connected to the given
" IP:PORT combination.
" A timer is started to send buffer contents to the super user at a specified
" delay.
" Finally, the username and password is sent to the server to confirm the 
" connection.
function! StartWriting(ip,name,pwd,delay) abort
    let s:send_data_channel = ch_open(a:ip . ":8765")
    let s:send_interval = timer_start(a:delay,'SendBufferContents',{'repeat' : -1})
    call ch_evalexpr(s:send_data_channel,"#1 " . a:name . " " . a:pwd)
endfunction
" }}}

" CloseChannelWrapper()----------------------------------------------------{{{
" Helper method to close the channel which the client has opened
function! CloseChannelWrapper() abort
    call ch_close(s:send_data_channel)
endfunction
" }}}

" SendBufferContents(timer)-----------------------------------------{{{
" Takes timerID as an argument as specified by the timer API in VIM.
function! SendBufferContents(timer) abort
    " l:buf stores a string which contains all the lines in the
    " buffer from the first to the last ('$').
    let l:contents= join(getline(1,'$'),"\n")
    if ch_status(s:send_data_channel) == "closed" 
        call timer_stop(s:send_interval)
        return
    endif
    call ch_sendexpr(s:send_data_channel,l:contents)
endfunction 
" }}}

" Disconnect(name,pwd)--------------------------------{{{ 
" Called by the client to disconnect from the super user
function! Disconnect(name,pwd) abort
    call ch_sendexpr(s:send_data_channel,"#last") 
    call ch_close(s:send_data_channel)
endfunction
"}}}

" StartReading()--------------------------------{{{
" Sets the value of g:thisBufname to the name of the
" buffer in which the cursor was in when this function
" was called. Then the server is started.
function! StartReading() abort
    let g:thisBufname = bufname("")
    call StartServer()
endfunction
" }}}

" StopReading(...)----------------------------------------------------------------{{{
" This function can take variable number of arguments. This allows it to act
" differently on the basis of the number of arguments. 
function! StopReading(...) abort
    " a:0 stores the number of extra arguments.
    if a:0 == 2
        " if a:1 is 1, that means that the super user wants to transfer
        " the contents of a certain buffer to the rest of the users.
        if a:1 == 1
            " Move to buffer a:2, copy the contents"
            execute "b!" a:2
            let l:contents = join(getline(1,'$'),"\n")
            " Move back to the previous buffer.
            execute "b! #"
python3 << EOF
contents = vim.eval("l:contents")
# For each key in the socketDictionary (which stores all the socket objects
# and gives them a key), send the contents and close the connection.
# The connection is closed by sending a command which the client executes.
# Since the plugin file is common to all VIM instances, the name of the 
# channel which each client uses (send_data_channel) is the same.
for key in socketDictionary:
    clearAndRewrite = "[\"ex\", \":normal! ggVGdi" + contents + "\"]"
    socketDictionary[key].sendall(clearAndRewrite.encode('utf-8'))
    closeConnection= "[\"call\", \"CloseChannelWrapper\", []]"
    socketDictionary[key].sendall(closeConnection.encode('utf-8'))
EOF
        endif
    else
" Alternatively, if no argument is closed, all the client connections
" are simply terminated.
python3 << EOF
for key in socketDictionary:
    closeConnection= "[\"call\", \"CloseChannelWrapper\", []]"
    socketDictionary[key].sendall(closeConnection.encode('utf-8'))
EOF
    endif
    " The different timer objects which shuttle around the buffers
    " and update the contents are stopped.
    for v in values(g:timer_dictionary)
        call timer_stop(v)
    endfor
endfunction
" }}}

" CleanAndRewrite(timerID)-------------------------------------------------{{{
" In the super user's VIM application, this method is executed with some
" time delay. It moves to the buffer whose name is currently stored in 
" g:currentBufName.
function! CleanAndRewrite(timerID) abort
    execute "b!" g:currentBufName
    " This cryptic sequence of commands moves to the top of the file,
    " enters line-wise visual mode. Moves cursor to the last line of
    " the file. Deletes all that has been selected.
    normal ggVGd
    " Inserts the text currently stored in g:newText.
    execute "normal! i" . g:newText
    " The following while loop keeps changing buffers till the loaded 
    " buffer is the same as the one in which StartReading() was 
    " called.
    let l:thatBufname = bufname("")
    while l:thatBufname !=# g:thisBufname
        execute "bp!"
        let l:thatBufname = bufname("")
    endwhile
endfunction
" }}}

" StartServer()------------------------------------------------------{{{
" Contains the classes and instrutions required to start the server.
function! StartServer() abort

python3 << EOF
import json
import socket
import sys
import threading
import socketserver
import vim

# Super User can set the password by changing the value of this 
# variable.
password = "p"
# Dictionary which stores the server side sockets which establish
# connections with the client, indexed by the username (also the 
# buffer name.
socketDictionary = {}

# We override the handle(self) method in socketserver.BaseRequestHandler
# class and define the behaviour for every client connection.
class RequestHandler(socketserver.BaseRequestHandler):

    # When a client connects to the server, this method is called.
    # For each connection, this method is called on a seperate thread.
    # This was very convenient for us. 
    def handle(self):
        global socketDictionary
        global password
        key = ""
        while True:
            try:
                # Over here we keep poling for content from the client
                # which is basically the contents of the buffer in which
                # the client is writing.
                data = self.request.recv(4096).decode('utf-8')
            except socket.error:
                print("Diconnected due to socket error") 
                break
            except IOError:
                print("Disconnected due to I/O error")
                break

            if data == '':
                print("Disconnected because of empty data string")
                break

            try:
                decoded = json.loads(data)
            except ValueError:
                print("json decoding failed")
                decoded = [-1, '']

            if decoded[0] == 1:
                # First time data is recieved, we check
                # whether the client has used the correct protocol
                # to establish a connection.
                tokens = decoded[1].split(" ")
                if tokens[0] == "#1":
                    # Confirm that the password specified by the client 
                    # is the same as the one set by the super user.
                    if tokens[2] == password:
                        # This server-side socket is stored in the 
                        # Dictionary with username as the key.
                        socketDictionary[tokens[1]] = self.request;
                        key = tokens[1]
                        # A new window is split for that client in the
                        # VIM application of the super user.
                        vim.command("vsplit " + key)
                        # This command returns the cursor to the window
                        # in which the super user was writing.
                        vim.command("normal \<c-w>\<c-p>")
                    else:
                        # If there is some error, the connection is terminated.
                        closeConnection= "[\"call\", \"CloseChannelWrapper\", []]"
                        self.request.sendall(closeConnection.encode('utf-8'))
            elif decoded[0] > 1: 
                if decoded[0] == 2:
                    vim.command("let g:timer_dictionary[\"" + key + "\"] = timer_start(4000,'CleanAndRewrite',{'repeat':-1})")  
                else:
                    # The values of g:newText and g:currentBufName are set
                    # to equal the most recently recieved data. Now this data
                    # will be displayed when CleanAndRewrite is called again. 
                    # Although is technically possible that each time the function
                    # is called, the values of the global variables is the same
                    # in which case the data of only one client will be displated.
                    # We had to use this round about manner because since, VIM
                    # isn't thread safe, we can't execute VIM commands from a 
                    # thread. It'll behave very unreliably (and possibly crash)
                    # if we attempt to do so.
                    vim.command("let g:newText = \"" + decoded[1] + "\"")
                    vim.command("let g:currentBufName = \"" + key + "\"")

        # When the connection is broken by the client, the socket object corresponding to that
        # connection is deleted.
        del socketDictionary[key] 
        
# Derived class from ThreadingMixIn (So that multiple connections
# can be handled concurrently and TCPServer. 
class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer): 
    pass

# Object s has no other purpose in life except to determine
# the IP of the Host. It does so by trying to connect to Google's
# DNS server. Once the connection is established, the IP of the host
# can be obtained by getsockname().
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

try:
    s.connect(("8.8.8.8",80))
except socket.error:
    print("Couldn't connect to host")

HOST1, PORT1 = s.getsockname()[0], 8765
s.close()
# To start the server.
# This code is based on the python documentation pages, whose link
# is available on the help page of this plugin under the citations
# section.
readServer = ThreadedTCPServer((HOST1,PORT1), RequestHandler)
ip1, port1 = readServer.server_address
readServer_thread = threading.Thread(target=readServer.serve_forever)
# This flag is set to true so that the server is closed once
# VIM is closed. If it was false, then the server would continue running
# on the daemon thread.
readServer_thread.daemon = True
readServer_thread.start()

EOF
endfunction
" }}}

" StopServer()-----------------------{{{
" Shuts the server down. Very important point to note
" in case it hasn't been noted already.
" The python3 << EOF command provides the exact same environment
" as a python interpreter. Also, any variable used earlier in
" another script (in a previously called function) is available 
" for later functions. 
function! StopServer()
python3 << EOF
readServer.shutdown()
readServer.server_close()
EOF
endfunction
" }}}
