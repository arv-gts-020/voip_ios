var apn = require("apn");
var deviceToken = "3fbfde904c3d1ebae50ea1b35937f66362be11265f6b718f5dd8be6ae36dfc87";
let provider = new apn.Provider( 
    {
        token: {
            key: "assets/authKey.p8",
            keyId: "J9X23FZCY8",
            teamId: "6Y772V7M27"
        },
        production: true
    });

let notification = new apn.Notification();
notification.rawPayload = {
    "aps": {
        "alert": {
            "uuid": "1b915738-1933-4174-8b0c-635bf2649e76",
            "incoming_caller_id": "instant_02UCM1718358136236gkQkK",
            "incoming_caller_name": "Audio Call From Arvindra Singh",
            "call_type": "video"
        }
    }
};
notification.pushType = "voip";
notification.topic = "com.karmm.app.voip";

/// for showing incoming call screen to the targeted device on call initiated by astro
provider.send(notification, deviceToken).then((err, result) => {
    if (err) return console.log(JSON.stringify(err));
    return console.log(JSON.stringify(result))
});




/// when astro cancel dialing calling then we can call this function
function sendCancelNotification(deviceToken, uuid) {
    let cancelNotification = new apn.Notification();
    cancelNotification.rawPayload = {
        "aps": {
            "alert": {
                "uuid": uuid,
                "call_status": "canceled"
            }
        }
    };
    cancelNotification.pushType = "voip";
    cancelNotification.topic = "com.karmm.app.voip";

    provider.send(cancelNotification, deviceToken).then((result) => {
        if (result.failed.length > 0) {
            console.log("Failed to send cancel notification:", result.failed);
        } else {
            console.log("Successfully sent cancel notification:", result.sent);
        }
    });
}

// Example usage to cancel the call
// setTimeout((deviceToken) => {

//     sendCancelNotification(deviceToken, "1b915738-1933-4174-8b0c-635bf2649e76");
// },10000,deviceToken);