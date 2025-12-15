//
//  ContentView.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/12.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = PlayerViewModel()
    @State var url = "rtsp://long:short@192.168.0.120:554/live/ch1"

    var body: some View {
        VStack {
            Text("RTSP URL")
                .foregroundColor(.gray)

            TextField("Enter RTSP URL", text: $url)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit {
                    Task {
                        await vm.connect(url: url)
                    }
                }
            
            HStack {
                Button("Connect") {
                    Task {
                        await vm.connect(url: url)
                    }
                }
                Button("Disconnect") { vm.disconnect() }
            }

            Text(vm.statusText)
                .font(.footnote)

        }
        .padding()
    }
}

#Preview {
    ContentView()
}
