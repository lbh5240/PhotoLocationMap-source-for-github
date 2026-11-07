package com.astra.starrynight;

import org.json.JSONArray;
import org.json.JSONObject;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.UUID;

final class Project {
    static final class Frame {
        String original, cache, name;
        int width, height;
        boolean included = true;
        JSONObject json() throws Exception {
            return new JSONObject().put("original", original).put("cache", cache).put("name", name)
                    .put("width", width).put("height", height).put("included", included);
        }
        static Frame read(JSONObject object) throws Exception {
            Frame f = new Frame();
            f.original = object.getString("original"); f.cache = object.getString("cache");
            f.name = object.getString("name"); f.width = object.getInt("width"); f.height = object.getInt("height");
            f.included = object.optBoolean("included", true);
            return f;
        }
    }
    final File directory;
    String name = "星空工程";
    ArrayList<Frame> frames = new ArrayList<>();
    String master;
    int width, height, accepted, mode;
    double sky = .65, exposure, contrast = 1, saturation = 1, warmth;
    double[] wheels = new double[9];

    Project(File directory) { this.directory = directory; }
    static Project create(File root) throws Exception {
        File directory = new File(root, UUID.randomUUID().toString());
        if (!directory.mkdirs()) throw new Exception("无法创建工程目录");
        Project p = new Project(directory);
        p.save();
        return p;
    }
    void save() throws Exception {
        JSONObject object = new JSONObject().put("name", name).put("width", width).put("height", height)
                .put("accepted", accepted).put("mode", mode).put("sky", sky)
                .put("exposure", exposure).put("contrast", contrast).put("saturation", saturation)
                .put("warmth", warmth).put("wheels", new JSONArray(wheels));
        if (master != null) object.put("master", master);
        JSONArray input = new JSONArray();
        for (Frame frame : frames) input.put(frame.json());
        object.put("frames", input);
        AtomicFile file = new AtomicFile(new File(directory, "project.json"));
        FileOutputStream stream = file.startWrite();
        try {
            stream.write(object.toString(2).getBytes(StandardCharsets.UTF_8));
            file.finishWrite(stream);
        } catch (Exception error) { file.failWrite(stream); throw error; }
    }
    static Project open(File directory) throws Exception {
        JSONObject object = new JSONObject(new String(Files.readAllBytes(new File(directory, "project.json").toPath()), StandardCharsets.UTF_8));
        Project p = new Project(directory);
        p.name = object.optString("name", "星空工程");
        p.width = object.optInt("width"); p.height = object.optInt("height"); p.accepted = object.optInt("accepted");
        p.mode = object.optInt("mode"); p.sky = object.optDouble("sky", .65);
        p.exposure = object.optDouble("exposure"); p.contrast = object.optDouble("contrast", 1);
        p.saturation = object.optDouble("saturation", 1); p.warmth = object.optDouble("warmth");
        p.master = object.has("master") ? object.getString("master") : null;
        JSONArray frames = object.getJSONArray("frames");
        for (int i = 0; i < frames.length(); i++) p.frames.add(Frame.read(frames.getJSONObject(i)));
        JSONArray wheels = object.optJSONArray("wheels");
        if (wheels != null && wheels.length() == 9) for (int i = 0; i < 9; i++) p.wheels[i] = wheels.getDouble(i);
        return p;
    }
    File file(String name) { return new File(directory, name); }
}
