var parsed_url = new URL(window.location.href);
var server_url = "http://" + window.location.hostname + ":" + window.location.port + "/fetch";
var xhttp      = new XMLHttpRequest();
var queue      = parsed_url.searchParams.get("queue");
var timer      = null;
if (queue) {
    server_url += "/" + queue;
}

function start_timer() {
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
            var msg = JSON.parse(this.responseText);
            if (queue) {
                display_queue(msg);
            }
            else {
                display_queues(msg);
            }
        }
        if (this.readyState == 4) {
            timer = setTimeout(tick, 2000);
        }
    };
    timer = setTimeout(tick, 0);
}

function tick() {
    xhttp.open("GET", server_url, true);
    xhttp.send();
}

function display_queue(msg) {
    var output = [];
    var footer = "";
    for (var i = 0; i < msg.length && i < 1000; i++) {
        var tr        = "";
        var date      = new Date();
        var next_date = new Date();
        date.setTime(
            ( msg[i].message_timestamp - date.getTimezoneOffset() * 60 )
            * 1000
        );
        next_date.setTime(
            ( msg[i].next_attempt - date.getTimezoneOffset() * 60 )
            * 1000
        );
        if (msg[i].attempts > 1) {
            tr = "<tr bgcolor=\"#FF9999\">";
        }
        else if (msg[i].attempts == 1) {
            tr = "<tr bgcolor=\"#99FF99\">";
        }
        else {
            tr = "<tr bgcolor=\"#DDDDDD\">";
        }
        var row = tr + "<td>" + date.toISOString()      + "</td>"
                     + "<td>" + msg[i].message_stream   + "</td>"
                     + "<td>" + msg[i].message_payload  + "</td>"
                     + "<td>" + msg[i].attempts         + "</td>"
                     + "<td>" + next_date.toISOString() + "</td></tr>";
        output.push(row);
    }
    if (msg.length == 0) {
        footer = "<em>-empty-</em>";
    }
    document.getElementById("output").innerHTML
                = "<table>"
                + "<tr><th>TIMESTAMP</th>"
                + "<th>KEY</th>"
                + "<th>VALUE</th>"
                + "<th># ATTEMPTS</th>"
                + "<th>NEXT ATTEMPT</th></tr>"
                + output.join("")
                + "</table>"
                + footer;
}

function display_queues(msg) {
    var output = [];
    var footer = "";
    msg.sort(function(a, b) {
        return b.size - a.size;
    });
    for (var i = 0; i < msg.length && i < 1000; i++) {
        var key_href = "<a href=\"queue.html?queue="
                     + msg[i].name + "\">"
                     + msg[i].name + "</a>";
        if (msg[i].size > 1000) {
            tr = "<tr bgcolor=\"#FF9999\">";
        }
        else if (msg[i].size > 0) {
            tr = "<tr bgcolor=\"#99FF99\">";
        }
        else {
            tr = "<tr bgcolor=\"#DDDDDD\">";
        }
        var row = tr + "<td>" + key_href    + "</td>"
                     + "<td>" + msg[i].size + "</td></tr>";
        output.push(row);
    }
    if (msg.length == 0) {
        footer = "<em>-none-</em>";
    }
    document.getElementById("output").innerHTML
                = "<table>"
                + "<tr><th>QUEUE</th>"
                + "<th>SIZE</th></tr>"
                + output.join("")
                + "</table>"
                + footer;
}
