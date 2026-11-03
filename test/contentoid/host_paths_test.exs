defmodule Contentoid.HostPathsTest do
  use ExUnit.Case, async: true

  import ContentoidWeb.Messages

  alias Contentoid.HostPaths

  # A container's mounts: overlay root, the usual pseudo filesystems, a hosts file and two bind
  # mounts, one with a space in its path.
  @mountinfo """
  612 540 0:63 / / rw,relatime master:208 - overlay overlay rw,lowerdir=/var/lib/docker/overlay2/l/X
  613 612 0:66 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
  614 612 0:67 / /dev rw,nosuid - tmpfs tmpfs rw,size=65536k,mode=755
  620 612 254:1 /docker/containers/abc/hosts /etc/hosts rw,relatime - ext4 /dev/vda1 rw
  621 612 254:1 /srv/media /srv/media rw,relatime - ext4 /dev/vda1 rw
  622 612 254:1 /srv/my\\040library /srv/my\\040library rw,relatime - ext4 /dev/vda1 rw
  """

  test "a path under a bind mount is fine" do
    assert HostPaths.warning("/srv/media", @mountinfo) == nil
    assert HostPaths.warning("/srv/media/videos", @mountinfo) == nil
    assert HostPaths.warning("/srv/my library/books", @mountinfo) == nil
  end

  test "a path only on the container's root filesystem is warned about" do
    assert message_text(HostPaths.warning("/app/downloads", @mountinfo)) =~ "/app/downloads isn't on a mount"
    # A mount point's name as a prefix isn't the mount.
    assert message_text(HostPaths.warning("/srv/media-old", @mountinfo)) =~ "/srv/media-old isn't on a mount"
  end
end
